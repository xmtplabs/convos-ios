import Combine
import Foundation
import GRDB

public protocol ContactsRepositoryProtocol: Sendable {
    /// Reactive publisher of all contacts ordered alphabetically by display
    /// name (case-insensitive). Includes blocked contacts so the browse list
    /// can render them with an unblock affordance. Callers that need an
    /// unblocked-only list (e.g. the picker) filter in the view layer.
    ///
    /// Agent contacts are collapsed to one row per `agentTemplateId`, carrying
    /// the canonical template identity (name + emoji) from the
    /// `DBAgentTemplate` cache. The list, picker, and contacts badge all read
    /// this single canonical shape, so they can never disagree on what a
    /// template-backed agent is called or how many contacts there are.
    var contactsPublisher: AnyPublisher<[Contact], Never> { get }

    /// Synchronous fetch of the alphabetical contact list. Includes blocked
    /// contacts and applies the same per-template agent collapsing as
    /// `contactsPublisher`.
    func fetchAll() throws -> [Contact]

    /// Indexed point read; returns true if the inboxId is present in the
    /// contact table. Blocked contacts still count as contacts.
    func isContact(inboxId: String) throws -> Bool

    /// Indexed point read; returns true if the inboxId has a non-nil
    /// `blockedAt` value. False for non-contacts and unblocked contacts.
    func isBlocked(inboxId: String) throws -> Bool

    /// Fetches a single contact by inboxId.
    func fetchContact(inboxId: String) throws -> Contact?

    /// Targeted lookup of the canonical agent contacts for the given
    /// template ids - at most one contact per id, with the same
    /// per-template collapsing as `fetchAll()`. Used by the picker flows
    /// to resolve picked agent templates without loading the whole
    /// contacts table. Ids with no contact row are absent from the
    /// result; order is unspecified.
    func fetchContacts(templateIds: [String]) throws -> [Contact]

    /// Batch lookup of source-conversation metadata (name + kind) for the
    /// "you met them in X" subtitle on contact rows. Callers index by
    /// `addedViaConversationId`. Missing ids are absent from the result
    /// (conversation was deleted, or the contact has no source convo).
    func sourceConversations(forIds ids: Set<String>) throws -> [String: ContactSourceConversation]
}

/// Minimal snapshot of the conversation that promoted an inbox to a
/// contact. Returned by `ContactsRepositoryProtocol.sourceConversations`.
public struct ContactSourceConversation: Sendable, Hashable {
    public let name: String?
    public let kind: ConversationKind

    public init(name: String?, kind: ConversationKind) {
        self.name = name
        self.kind = kind
    }
}

extension ContactsRepositoryProtocol {
    /// Authoritative inbox-to-contact lookup for the UI's "contact data
    /// overrides per-conversation profile data" rule. Returns the
    /// stored contact when the inbox is a known contact, otherwise
    /// `nil` so the caller's fallback (per-conversation profile) applies.
    ///
    /// This is the canonical entry point for the
    /// `memberContactOverride: @Sendable (String) -> Contact?` resolver
    /// passed through the SwiftUI environment and the chat-layer
    /// plumbing. UI sites adapt it as needed: text uses `?.displayName`
    /// (with empty-string fallback), avatar rendering uses the full
    /// contact for name + encrypted-image fields. Storage errors are
    /// swallowed as `nil` since render-site callers cannot usefully
    /// handle a thrown error mid-paint.
    public func contact(for inboxId: String) -> Contact? {
        try? fetchContact(inboxId: inboxId)
    }

    /// Default `fetchContacts(templateIds:)` backed by `fetchAll()`, so
    /// mock conformers stay minimal. The live repository overrides this
    /// with an indexed query.
    public func fetchContacts(templateIds: [String]) throws -> [Contact] {
        guard !templateIds.isEmpty else { return [] }
        let ids = Set(templateIds)
        return try fetchAll().filter { contact in
            guard let templateId = contact.agentTemplateId else { return false }
            return ids.contains(templateId)
        }
    }

    /// Convenience adapter for ConvosCore APIs that take a name-only
    /// `(String) -> String?` resolver (`Conversation.computedDisplayName`,
    /// `ConversationMember.displayName`, `ConversationUpdate.summary`).
    /// Returns the contact's display name when present and non-empty,
    /// otherwise `nil` so the caller's fallback chain applies.
    public func contactName(for inboxId: String) -> String? {
        guard let name = contact(for: inboxId)?.displayName, !name.isEmpty else {
            return nil
        }
        return name
    }
}

final class ContactsRepository: ContactsRepositoryProtocol, @unchecked Sendable {
    private let databaseReader: any DatabaseReader

    let contactsPublisher: AnyPublisher<[Contact], Never>

    init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
        self.contactsPublisher = ValueObservation
            .tracking { db in
                try ContactsRepository.canonicalContacts(db)
            }
            .publisher(in: databaseReader)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    func fetchAll() throws -> [Contact] {
        try databaseReader.read { db in
            try ContactsRepository.canonicalContacts(db)
        }
    }

    func isContact(inboxId: String) throws -> Bool {
        try databaseReader.read { db in
            try DBContact
                .filter(DBContact.Columns.inboxId == inboxId)
                .fetchCount(db) > 0
        }
    }

    func isBlocked(inboxId: String) throws -> Bool {
        try databaseReader.read { db in
            try DBContact
                .filter(DBContact.Columns.inboxId == inboxId)
                .filter(DBContact.Columns.blockedAt != nil)
                .fetchCount(db) > 0
        }
    }

    func fetchContact(inboxId: String) throws -> Contact? {
        try databaseReader.read { db in
            try DBContact.fetchOne(db, key: inboxId).map(Contact.init(dbContact:))
        }
    }

    /// Indexed variant of the protocol's default implementation: fetches
    /// only rows whose `agentTemplateId` is in `templateIds`, then applies
    /// the same canonical per-template collapsing as `fetchAll()`. The
    /// fetch order matches `canonicalContacts` so the representative
    /// chosen per template is identical to the browse list's.
    func fetchContacts(templateIds: [String]) throws -> [Contact] {
        guard !templateIds.isEmpty else { return [] }
        return try databaseReader.read { db in
            let templates = try ContactsRepository.templateMap(db)
            return try DBContact
                .filter(templateIds.contains(DBContact.Columns.agentTemplateId))
                .order(DBContact.Columns.addedAt, DBContact.Columns.inboxId)
                .fetchAll(db)
                .map(Contact.init(dbContact:))
                .dedupingAgentsByTemplate(using: templates)
        }
    }

    /// In-transaction variant of `contactName(for:)` for callers already
    /// inside a database read (e.g. notification display-name resolution).
    /// Returns the contact's display name when present and non-empty,
    /// otherwise `nil` so the caller's fallback chain (per-conversation
    /// profile name, then "Agent" / "Somebody") applies.
    static func contactNameInTransaction(db: Database, inboxId: String) throws -> String? {
        guard let name = try DBContact.fetchOne(db, key: inboxId)?.displayName, !name.isEmpty else {
            return nil
        }
        return name
    }

    /// Bulk inbox-id -> contact display-name resolver for hydration. Returns a
    /// closure backed by a single fetch of the `contact` table; empty names are
    /// omitted so a missing key means "no contact name" and the caller's
    /// fallback applies. Building this inside a `ValueObservation` read closure
    /// also registers the observation on the `contact` table, so a contact
    /// rename refreshes surfaces hydrated through the resolver.
    static func contactNameResolverInTransaction(db: Database) throws -> (String) -> String? {
        let names: [String: String] = try DBContact
            .fetchAll(db)
            .reduce(into: [:]) { map, contact in
                if let name = contact.displayName, !name.isEmpty {
                    map[contact.inboxId] = name
                }
            }
        return { names[$0] }
    }

    func sourceConversations(forIds ids: Set<String>) throws -> [String: ContactSourceConversation] {
        guard !ids.isEmpty else { return [:] }
        return try databaseReader.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let rows = try GRDB.Row.fetchAll(
                db,
                sql: "SELECT id, name, kind FROM conversation WHERE id IN (\(placeholders))",
                arguments: StatementArguments(Array(ids))
            )
            var result: [String: ContactSourceConversation] = [:]
            for row in rows {
                guard let id: String = row["id"] else { continue }
                guard let kindRaw: String = row["kind"],
                      let kind = ConversationKind(rawValue: kindRaw) else { continue }
                let name: String? = row["name"]
                let trimmed: String? = name.flatMap { $0.isEmpty ? nil : $0 }
                result[id] = ContactSourceConversation(name: trimmed, kind: kind)
            }
            return result
        }
    }

    /// Fetches contacts, collapses agent instances to one canonical row per
    /// `agentTemplateId` using the `DBAgentTemplate` cache, then sorts. The
    /// cache join happens here (not in the view layer) so every browse
    /// surface consumes the same canonical shape from a single observation.
    private static func canonicalContacts(_ db: Database) throws -> [Contact] {
        let templates = try templateMap(db)
        // Deterministic fetch order so the representative chosen per template
        // (the first encountered by `dedupingAgentsByTemplate`) is stable
        // across observations - earliest-added, then inboxId as a tiebreak.
        // Dedup before sorting so the canonical (merged) display name is what
        // drives alphabetical order. Case-insensitive sort done in Swift to
        // keep behavior identical across SQLite collations; nil names defer to
        // the "Somebody" fallback in resolvedDisplayName.
        return try DBContact
            .order(DBContact.Columns.addedAt, DBContact.Columns.inboxId)
            .fetchAll(db)
            .map(Contact.init(dbContact:))
            .dedupingAgentsByTemplate(using: templates)
            .sorted { lhs, rhs in
                lhs.resolvedDisplayName
                    .localizedCaseInsensitiveCompare(rhs.resolvedDisplayName) == .orderedAscending
            }
    }

    private static func templateMap(_ db: Database) throws -> [String: AgentTemplateInfo] {
        try DBAgentTemplate.fetchAll(db).reduce(into: [:]) { map, row in
            map[row.templateId] = AgentTemplateInfo(
                templateId: row.templateId,
                agentName: row.agentName,
                emoji: row.emoji,
                avatarURL: row.avatarURL,
                publishedURL: row.publishedURL
            )
        }
    }
}
