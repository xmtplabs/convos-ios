import Combine
import Foundation
import GRDB

public protocol ContactsRepositoryProtocol: Sendable {
    /// Reactive publisher of all contacts ordered alphabetically by display
    /// name (case-insensitive). Includes blocked contacts so the browse list
    /// can render them with an unblock affordance. Callers that need an
    /// unblocked-only list (e.g. the picker) filter in the view layer.
    var contactsPublisher: AnyPublisher<[Contact], Never> { get }

    /// Synchronous fetch of the alphabetical contact list. Includes blocked
    /// contacts; see `contactsPublisher` for the rationale.
    func fetchAll() throws -> [Contact]

    /// Indexed point read; returns true if the inboxId is present in the
    /// contact table. Blocked contacts still count as contacts.
    func isContact(inboxId: String) throws -> Bool

    /// Indexed point read; returns true if the inboxId has a non-nil
    /// `blockedAt` value. False for non-contacts and unblocked contacts.
    func isBlocked(inboxId: String) throws -> Bool

    /// Fetches a single contact by inboxId.
    func fetchContact(inboxId: String) throws -> Contact?

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
                try ContactsRepository.fetchAllContacts(db)
            }
            .publisher(in: databaseReader)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    func fetchAll() throws -> [Contact] {
        try databaseReader.read { db in
            try ContactsRepository.fetchAllContacts(db)
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

    private static func fetchAllContacts(_ db: Database) throws -> [Contact] {
        let rows = try DBContact.fetchAll(db)
        // Case-insensitive sort done in Swift to keep behavior identical
        // across SQLite collations (idx_contact_displayName supports first
        // paint; the in-memory sort handles nil names by deferring to the
        // "Somebody" fallback in resolvedDisplayName).
        return rows
            .map(Contact.init(dbContact:))
            .sorted { lhs, rhs in
                lhs.resolvedDisplayName
                    .localizedCaseInsensitiveCompare(rhs.resolvedDisplayName) == .orderedAscending
            }
    }
}
