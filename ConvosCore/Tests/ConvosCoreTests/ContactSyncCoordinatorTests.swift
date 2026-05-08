@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ContactSyncCoordinator Tests", .serialized)
struct ContactSyncCoordinatorTests {
    private static func seedConversation(
        db: Database,
        conversationId: String,
        creatorInboxId: String,
        memberInboxIds: [String],
        memberProfiles: [String: (name: String?, avatar: String?)] = [:]
    ) throws {
        try DBMember(inboxId: creatorInboxId).save(db, onConflict: .ignore)
        for inboxId in memberInboxIds {
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        }

        try DBConversation(
            id: conversationId,
            clientConversationId: conversationId,
            inviteTag: "tag-\(conversationId)",
            creatorId: creatorInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAssistant: false
        ).insert(db)

        for inboxId in memberInboxIds {
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: inboxId,
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).save(db)

            if let profile = memberProfiles[inboxId] {
                try DBMemberProfile(
                    conversationId: conversationId,
                    inboxId: inboxId,
                    name: profile.name,
                    avatar: profile.avatar
                ).save(db)
            }
        }
    }

    @Test("syncContacts pulls non-self members into contacts and writes a sync marker")
    func testSyncContactsHappyPath() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice", "bob"],
                memberProfiles: [
                    "alice": (name: "Alice", avatar: "https://example.com/a.png"),
                    "bob": (name: "Bob", avatar: nil)
                ]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContacts(for: conversationId, force: false)

        let contacts: [DBContact] = try await dbManager.dbReader.read { db in
            try DBContact.fetchAll(db)
        }
        #expect(Set(contacts.map(\.inboxId)) == Set(["alice", "bob"]))
        let alice = contacts.first { $0.inboxId == "alice" }
        #expect(alice?.displayName == "Alice")
        #expect(alice?.avatarURL == "https://example.com/a.png")
        #expect(alice?.addedViaConversationId == conversationId)

        let marker = try await dbManager.dbReader.read { db in
            try DBConversationContactsSync.fetchOne(db, key: conversationId)
        }
        #expect(marker != nil)
    }

    @Test("syncContacts is idempotent — second call short-circuits and preserves addedAt")
    func testSyncContactsIdempotent() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContacts(for: conversationId, force: false)

        let firstAddedAt = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: "alice")?.addedAt
        }

        try await Task.sleep(nanoseconds: 5_000_000)

        try await coordinator.syncContacts(for: conversationId, force: false)

        let secondAddedAt = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: "alice")?.addedAt
        }
        #expect(firstAddedAt == secondAddedAt)
    }

    @Test("force-rerun on never-synced conversation skips when local user is not the creator")
    func testForceRerunSkipsNeverSyncedConversation() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                // Creator is someone else — the local user was invited.
                creatorInboxId: "other-inbox",
                memberInboxIds: ["other-inbox", selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContacts(for: conversationId, force: true)

        let contacts: [DBContact] = try await dbManager.dbReader.read { db in
            try DBContact.fetchAll(db)
        }
        #expect(contacts.isEmpty, "Action-gated rule must skip when local user is not the conversation creator")
    }

    @Test("force-rerun on never-synced conversation proceeds when local user is the creator")
    func testForceRerunProceedsForCreator() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                // Local user created this group — bypass the action-gate.
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice", "bob"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContacts(for: conversationId, force: true)

        let contactIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds == Set(["alice", "bob"]), "Self-as-creator should bypass the action-gate")

        // Marker should also be written, so future first-message hooks
        // are no-ops on this conversation.
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == true)
    }

    @Test("force-rerun on already-synced conversation pulls in newly added members")
    func testForceRerunPicksUpNewMembers() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContacts(for: conversationId, force: false)

        // Add a new member after the initial sync.
        try await dbManager.dbWriter.write { db in
            try DBMember(inboxId: "carol").save(db, onConflict: .ignore)
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: "carol",
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).save(db)
        }

        try await coordinator.syncContacts(for: conversationId, force: true)

        let contactIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds == Set(["alice", "carol"]))
    }

    @Test("self inbox is excluded from contacts")
    func testSelfSkip() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContacts(for: conversationId, force: false)

        let inboxIds: [String] = try await dbManager.dbReader.read { db in
            try DBContact.fetchAll(db).map(\.inboxId)
        }
        #expect(!inboxIds.contains(selfInboxId))
    }

    @Test("syncContacts no-ops when selfInboxIdProvider returns nil (across both pre-fix-broken quadrants)")
    func testSyncContactsNoOpsWhenSelfUnknown() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        // Seed a conversation but deliberately omit the DBInbox row so the
        // default selfInboxIdProvider would return nil. We also pass an
        // explicit nil-returning provider here to make the contract explicit.
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice", "bob"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            selfInboxIdProvider: { _ in nil }
        )

        // Quadrant 1: first-message hook on never-synced (force=false). Pre-fix
        // this fell through both short-circuits and upserted every member,
        // including the local user, because the per-iteration self-skip guard
        // can't fire when self is nil.
        try await coordinator.syncContacts(for: conversationId, force: false)

        var contactIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds.isEmpty, "Sync must no-op when self is unknown — no contacts should be written")
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == false, "No marker should be written when self is unknown")

        // Seed a marker so the next call hits the (alreadySynced=true,
        // force=true) quadrant — the other path that was previously broken.
        try await dbManager.dbWriter.write { db in
            try DBConversationContactsSync(
                conversationId: conversationId,
                contactsSyncedAt: Date()
            ).save(db)
        }

        // Quadrant 2: member-added hook on already-synced. Pre-fix this fell
        // through both short-circuits the same way.
        try await coordinator.syncContacts(for: conversationId, force: true)

        contactIds = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(contactIds.isEmpty, "Forced sync must also no-op when self is unknown")
    }

    @Test("hasSyncedContacts mirrors marker presence")
    func testHasSyncedContacts() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == false)
        try await coordinator.syncContacts(for: conversationId, force: false)
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == true)
    }

    @Test("syncContacts skips the marker when only self is present so a later sync can retry")
    func testEmptyRosterDefersMarker() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"
        let conversationId = "conv-1"

        // Initial state: peer rows have not yet streamed in — only self is
        // a member. This mirrors the race we saw in the field where the
        // first-message hook fires before the StreamProcessor commits the
        // peer's `conversation_members` row.
        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)
            try Self.seedConversation(
                db: db,
                conversationId: conversationId,
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId]
            )
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        try await coordinator.syncContacts(for: conversationId, force: false)

        // No contacts and no marker — we deliberately deferred so the next
        // outbound message gets another chance.
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == false)
        let count = try await dbManager.dbReader.read { db in
            try DBContact.fetchCount(db)
        }
        #expect(count == 0)

        // Peer arrives.
        try await dbManager.dbWriter.write { db in
            try DBMember(inboxId: "alice").save(db, onConflict: .ignore)
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: "alice",
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).save(db)
        }

        // Next sync (e.g. from the next outbound message) lands the contact
        // and writes the marker.
        try await coordinator.syncContacts(for: conversationId, force: false)
        #expect(try coordinator.hasSyncedContacts(for: conversationId) == true)
        let inboxIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(inboxIds == Set(["alice"]))
    }
}
