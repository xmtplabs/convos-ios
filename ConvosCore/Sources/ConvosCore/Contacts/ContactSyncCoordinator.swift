import Foundation
import GRDB

public protocol ContactSyncCoordinatorProtocol: Sendable {
    /// Idempotent. For the supplied conversation, ensures every non-self
    /// member has a row in the `contact` table and that the conversation has
    /// a `conversation_contacts_sync` marker.
    ///
    /// - Parameters:
    ///   - conversationId: the conversation to sync.
    ///   - force: when true, the coordinator runs even if the conversation
    ///     already has a sync marker (used for the member-added hook so a
    ///     newly added member is pulled into contacts on top of an
    ///     already-acted-in conversation).
    func syncContacts(for conversationId: String, force: Bool) async throws

    /// Returns true when the supplied conversation already has a sync marker
    /// — i.e. the local user has acted in this conversation in the past.
    func hasSyncedContacts(for conversationId: String) throws -> Bool
}

extension ContactSyncCoordinatorProtocol {
    public func syncContacts(for conversationId: String) async throws {
        try await syncContacts(for: conversationId, force: false)
    }
}

/// Single entry point for the auto-add work described in the contact list PRD.
/// Wraps `ContactsWriter` and reads from the existing `conversation_members`
/// and `memberProfile` tables to seed each new contact with a profile snapshot.
final class ContactSyncCoordinator: ContactSyncCoordinatorProtocol, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader

    /// Closure that returns the local user's `inboxId`. Called within the
    /// sync transaction so the lookup hits the same snapshot as the member
    /// read. Returns nil only when the inbox singleton has not yet been
    /// written, in which case the sync no-ops (auto-add cannot meaningfully
    /// happen without knowing who "self" is).
    private let selfInboxIdProvider: @Sendable (Database) throws -> String?

    init(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        selfInboxIdProvider: @escaping @Sendable (Database) throws -> String? = ContactSyncCoordinator.defaultSelfInboxIdProvider
    ) {
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.selfInboxIdProvider = selfInboxIdProvider
    }

    static func defaultSelfInboxIdProvider(_ db: Database) throws -> String? {
        try DBInbox.fetchAll(db).first?.inboxId
    }

    func hasSyncedContacts(for conversationId: String) throws -> Bool {
        try databaseReader.read { db in
            try DBConversationContactsSync
                .filter(DBConversationContactsSync.Columns.conversationId == conversationId)
                .fetchCount(db) > 0
        }
    }

    func syncContacts(for conversationId: String, force: Bool) async throws {
        try await databaseWriter.write { [selfInboxIdProvider] db in
            // Two short-circuits:
            //   - first-message hook on an already-synced conversation:
            //     no-op via `!force` (the network-side member-add hook in
            //     `ConversationWriter` and the local `addMembers` hook are
            //     responsible for picking up later joiners).
            //   - member-added hook on a never-synced conversation: skip,
            //     so we honor the action-gated rule and don't pull
            //     strangers from a group the local user has not acted in.
            let alreadySynced = try DBConversationContactsSync
                .filter(DBConversationContactsSync.Columns.conversationId == conversationId)
                .fetchCount(db) > 0

            if alreadySynced == false && force == true {
                Log.debug("Skipping forced contacts sync for never-synced conversation \(conversationId)")
                return
            }

            if alreadySynced && force == false {
                return
            }

            let selfInboxId = try selfInboxIdProvider(db)

            let members = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .fetchAll(db)

            let profiles = try DBMemberProfile
                .filter(DBMemberProfile.Columns.conversationId == conversationId)
                .fetchAll(db)
            let profilesByInboxId: [String: DBMemberProfile] = Dictionary(
                uniqueKeysWithValues: profiles.map { ($0.inboxId, $0) }
            )

            var upsertedCount: Int = 0
            for member in members {
                if let selfInboxId, member.inboxId == selfInboxId {
                    continue
                }
                let profile = profilesByInboxId[member.inboxId]
                let snapshot = ContactProfileSnapshot(
                    displayName: profile?.name,
                    avatarURL: profile?.avatar,
                    bio: nil,
                    profileUpdatedAt: nil
                )
                try ContactsWriter.upsertContactInTransaction(
                    db: db,
                    inboxId: member.inboxId,
                    addedViaConversationId: conversationId,
                    profile: snapshot
                )
                upsertedCount += 1
            }

            // Only mark the conversation synced if we actually upserted at
            // least one non-self contact. The first-message hook can race
            // ahead of the StreamProcessor / invite-join writers that
            // populate `conversation_members`; if the coordinator finds an
            // empty roster we leave the marker absent so the next outbound
            // message retries the sync once the peer rows have streamed in.
            // Tradeoff: a legitimate one-person group (only self) will retry
            // on every send. Acceptable — it's a few indexed reads.
            guard upsertedCount > 0 else {
                Log.debug("Contacts sync for \(conversationId) saw no non-self members; skipping marker so next message retries")
                return
            }

            let marker = DBConversationContactsSync(
                conversationId: conversationId,
                contactsSyncedAt: Date()
            )
            try marker.save(db)

            Log.debug("Synced \(upsertedCount) contacts for conversation \(conversationId) (force=\(force))")
        }
    }
}
