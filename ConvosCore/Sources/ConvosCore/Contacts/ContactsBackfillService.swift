import Foundation
import GRDB

// MARK: - One-time migration
//
// MIGRATION CODE — TARGETED FOR REMOVAL.
//
// The contacts list shipped with this version. Installs that upgraded from
// a prior version need their `contact` table seeded from the conversations
// they have already acted in (the new feature would otherwise show an empty
// list until the user re-sent a message in each existing conversation).
// `ContactsBackfillService` is that one-time seeding job.
//
// Once every active install has run this once, the steady-state triggers
// keep `contact` correct without any backfill:
//   - first-outbound-message hook in `OutgoingMessageWriter`
//   - addMembers hook in `ConversationMetadataWriter`
//   - network-side member-commit hook in `ConversationWriter`
//   - profile-sync hooks at every `DBMemberProfile` save site
//
// Deletion criteria: ~90 days after broad adoption (or whenever telemetry
// shows >99% of active installs already have contacts populated). When you
// delete:
//   - this file
//   - the `contactsBackfillService()` factory on `MessagingService` and the
//     matching protocol method
//   - `MessagingService.scheduleContactsBackfill()` and its call site in
//     init
//   - `ContactsBackfillServiceTests`
//   - the `MockContactsBackfillService` mock
//

public protocol ContactsBackfillServiceProtocol: Sendable {
    /// One-time backfill that scans every conversation the local user has
    /// taken explicit action in (i.e. has at least one outbound message)
    /// without an existing `conversation_contacts_sync` marker, and runs the
    /// contact-sync coordinator for each.
    ///
    /// Idempotent across launches — once a conversation has a sync marker it
    /// is skipped on subsequent runs.
    func backfillIfNeeded() async throws
}

final class ContactsBackfillService: ContactsBackfillServiceProtocol, @unchecked Sendable {
    private let databaseReader: any DatabaseReader
    private let coordinator: any ContactSyncCoordinatorProtocol
    private let selfInboxIdProvider: @Sendable (Database) throws -> String?

    init(
        databaseReader: any DatabaseReader,
        coordinator: any ContactSyncCoordinatorProtocol,
        selfInboxIdProvider: @escaping @Sendable (Database) throws -> String? = ContactSyncCoordinator.defaultSelfInboxIdProvider
    ) {
        self.databaseReader = databaseReader
        self.coordinator = coordinator
        self.selfInboxIdProvider = selfInboxIdProvider
    }

    func backfillIfNeeded() async throws {
        let candidates: [String] = try await databaseReader.read { [selfInboxIdProvider] db in
            guard let selfInboxId = try selfInboxIdProvider(db), !selfInboxId.isEmpty else {
                return []
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT m.conversationId
                FROM message AS m
                LEFT JOIN conversation_contacts_sync AS s
                    ON s.conversationId = m.conversationId
                WHERE m.senderId = ?
                  AND s.conversationId IS NULL
                """, arguments: [selfInboxId])
            return rows.compactMap { $0["conversationId"] as String? }
        }

        guard !candidates.isEmpty else {
            Log.debug("ContactsBackfillService: no conversations need backfill")
            return
        }

        Log.info("ContactsBackfillService: backfilling \(candidates.count) conversations")
        for conversationId in candidates {
            do {
                try await coordinator.syncContacts(for: conversationId, force: false)
            } catch {
                Log.error("ContactsBackfillService: failed sync for \(conversationId): \(error)")
            }
        }
    }
}
