import Foundation
import GRDB

public protocol ContactSyncCoordinatorProtocol: Sendable {
    /// First-message hook: idempotent sync that skips if the conversation
    /// already has a `conversation_contacts_sync` marker. Used by
    /// `OutgoingMessageWriter` when the local user sends a message; the
    /// no-op-if-synced semantic means subsequent messages in the same
    /// conversation are cheap.
    func syncContactsOnFirstMessage(for conversationId: String) async throws

    /// Membership-change hook: forced sync that runs even on an already-
    /// synced conversation, so newly arrived members are pulled into
    /// contacts. Used by `ConversationWriter` (after a network-driven
    /// member commit) and `ConversationMetadataWriter.addMembers`. The
    /// coordinator still honors the action-gated rule by short-circuiting
    /// when the conversation has never been synced (i.e. the local user
    /// has not acted there), unless the local user is the creator.
    func syncContactsAfterMembershipChange(for conversationId: String) async throws

    /// Returns true when the supplied conversation already has a sync
    /// marker, i.e. the local user has acted in this conversation in the
    /// past.
    func hasSyncedContacts(for conversationId: String) throws -> Bool
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

    func syncContactsOnFirstMessage(for conversationId: String) async throws {
        try await sync(conversationId: conversationId, force: false)
    }

    func syncContactsAfterMembershipChange(for conversationId: String) async throws {
        try await sync(conversationId: conversationId, force: true)
    }

    private func sync(conversationId: String, force: Bool) async throws {
        let insertedInboxIds: [String] = try await databaseWriter.write { [selfInboxIdProvider] db in
            // Without the local inbox singleton we cannot identify "self" and
            // therefore cannot exclude the local user from the upsert loop.
            // No-op rather than risk adding self as a contact. The next hook
            // (after the singleton is written) retries.
            guard let selfInboxId = try selfInboxIdProvider(db) else {
                Log.debug("Skipping contacts sync for \(conversationId): inbox singleton not written yet")
                return []
            }

            // Two short-circuits:
            //   - first-message hook on an already-synced conversation:
            //     no-op via `!force` (the network-side member-add hook in
            //     `ConversationWriter` and the local `addMembers` hook are
            //     responsible for picking up later joiners).
            //   - member-added hook on a never-synced conversation: skip,
            //     so we honor the action-gated rule and don't pull
            //     strangers from a group the local user has not acted in.
            //     Exception: if the local user is the creator of the
            //     conversation, creating the group is itself the explicit
            //     action - no need to wait for a first message.
            let alreadySynced = try DBConversationContactsSync
                .filter(DBConversationContactsSync.Columns.conversationId == conversationId)
                .fetchCount(db) > 0

            if alreadySynced == false && force == true {
                let creatorId = try DBConversation
                    .filter(DBConversation.Columns.id == conversationId)
                    .fetchOne(db)?.creatorId
                let selfIsCreator: Bool = {
                    guard let creatorId else { return false }
                    return creatorId == selfInboxId
                }()
                guard selfIsCreator else {
                    Log.debug("Skipping forced contacts sync for never-synced conversation \(conversationId) (local user is not the creator)")
                    return []
                }
                Log.debug("Forced contacts sync proceeding for never-synced conversation \(conversationId) (local user is the creator)")
            }

            if alreadySynced && force == false {
                return []
            }

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
            var insertedIds: [String] = []
            for member in members {
                if member.inboxId == selfInboxId {
                    continue
                }
                let profile = profilesByInboxId[member.inboxId]
                let snapshot = ContactProfileSnapshot(
                    displayName: profile?.name,
                    avatarURL: profile?.avatar,
                    avatarSalt: profile?.avatarSalt,
                    avatarNonce: profile?.avatarNonce,
                    avatarKey: profile?.avatarKey,
                    profileUpdatedAt: nil,
                    // Derived from the stored memberKind. nil means no agent
                    // signal (preserve existing); .agent / .verifiedConvos /
                    // .verifiedUserOAuth map to the corresponding
                    // AgentVerification.
                    agentVerification: profile?.memberKind?.agentVerification
                )
                let didInsert = try ContactsWriter.upsertContactInTransaction(
                    db: db,
                    inboxId: member.inboxId,
                    addedViaConversationId: conversationId,
                    profile: snapshot
                )
                if didInsert {
                    insertedIds.append(member.inboxId)
                }
                upsertedCount += 1
            }

            // Only mark the conversation synced if we actually upserted at
            // least one non-self contact. The first-message hook can race
            // ahead of the StreamProcessor / invite-join writers that
            // populate `conversation_members`; if the coordinator finds an
            // empty roster we leave the marker absent so the next outbound
            // message retries the sync once the peer rows have streamed in.
            // Tradeoff: a legitimate one-person group (only self) will retry
            // on every send. Acceptable - it's a few indexed reads.
            guard upsertedCount > 0 else {
                Log.debug("Contacts sync for \(conversationId) saw no non-self members; skipping marker so next message retries")
                return []
            }

            let marker = DBConversationContactsSync(
                conversationId: conversationId,
                contactsSyncedAt: Date()
            )
            try marker.save(db)

            Log.debug("Synced \(upsertedCount) contacts for conversation \(conversationId) (force=\(force))")
            return insertedIds
        }

        // Post after the transaction commits so the `QuarantineSweeper`
        // observer in `SessionManager` runs against committed contact rows.
        // A single notification per batch coalesces the whole group sync
        // into one sweep, no debounce timer required.
        ContactsWriter.postContactsWereAdded(inboxIds: insertedInboxIds)
    }
}
