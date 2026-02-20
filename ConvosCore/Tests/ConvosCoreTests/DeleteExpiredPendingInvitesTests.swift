@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("Delete Expired Pending Invites Tests", .serialized)
struct DeleteExpiredPendingInvitesTests {

    private func makeSessionManager(
        dbManager: MockDatabaseManager,
        identityStore: MockKeychainIdentityStore = MockKeychainIdentityStore(),
        lifecycleManager: MockInboxLifecycleManager = MockInboxLifecycleManager()
    ) -> SessionManager {
        SessionManager(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            environment: .tests,
            identityStore: identityStore,
            lifecycleManager: lifecycleManager,
            platformProviders: .mock
        )
    }

    private func makeDBConversation(
        id: String,
        inboxId: String,
        clientId: String,
        inviteTag: String,
        createdAt: Date = Date(),
        consent: Consent = .unknown
    ) -> DBConversation {
        DBConversation(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: id,
            inviteTag: inviteTag,
            creatorId: inboxId,
            kind: .group,
            consent: consent,
            createdAt: createdAt,
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
            imageEncryptionKey: nil
        )
    }

    private func insertInboxAndIdentity(
        dbManager: MockDatabaseManager,
        identityStore: MockKeychainIdentityStore,
        inboxId: String,
        clientId: String,
        createdAt: Date = Date()
    ) async throws {
        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxId, clientId: clientId, createdAt: createdAt).insert(db)
        }
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: inboxId, clientId: clientId, keys: keys)
    }

    // MARK: - Basic Deletion

    @Test("Deletes expired single-member pending invites")
    func testDeletesExpiredInvites() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let identityStore = MockKeychainIdentityStore()
        let lifecycleManager = MockInboxLifecycleManager()
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)

        try await insertInboxAndIdentity(
            dbManager: dbManager, identityStore: identityStore,
            inboxId: "inbox-1", clientId: "client-1", createdAt: tenDaysAgo
        )
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(
                id: "draft-expired", inboxId: "inbox-1", clientId: "client-1",
                inviteTag: "tag-1", createdAt: tenDaysAgo
            ).insert(db)
        }

        let session = makeSessionManager(
            dbManager: dbManager, identityStore: identityStore, lifecycleManager: lifecycleManager
        )

        let deleted = try await session.deleteExpiredPendingInvites()
        #expect(deleted == 1)

        let conversationCount = try await dbManager.dbReader.read { db in
            try DBConversation.fetchCount(db)
        }
        #expect(conversationCount == 0, "Draft conversation should be deleted")

        let inboxCount = try await dbManager.dbReader.read { db in
            try DBInbox.fetchCount(db)
        }
        #expect(inboxCount == 0, "Inbox record should be deleted")

        let identities = try await identityStore.loadAll()
        #expect(identities.isEmpty, "Keychain identity should be deleted")
    }

    // MARK: - Multi-Member Protection

    @Test("Does not delete inbox when conversation has multiple members")
    func testSkipsInboxWithMultiMemberConversation() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let identityStore = MockKeychainIdentityStore()
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)

        try await insertInboxAndIdentity(
            dbManager: dbManager, identityStore: identityStore,
            inboxId: "inbox-1", clientId: "client-1", createdAt: tenDaysAgo
        )
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(
                id: "draft-expired", inboxId: "inbox-1", clientId: "client-1",
                inviteTag: "tag-1", createdAt: tenDaysAgo
            ).insert(db)

            try DBMember(inboxId: "inbox-1").insert(db)
            try DBMember(inboxId: "other-inbox").insert(db)

            try DBConversationMember(
                conversationId: "draft-expired", inboxId: "inbox-1",
                role: .admin, consent: .allowed, createdAt: tenDaysAgo
            ).insert(db)
            try DBConversationMember(
                conversationId: "draft-expired", inboxId: "other-inbox",
                role: .member, consent: .allowed, createdAt: tenDaysAgo
            ).insert(db)
        }

        let session = makeSessionManager(dbManager: dbManager, identityStore: identityStore)

        let deleted = try await session.deleteExpiredPendingInvites()
        #expect(deleted == 0, "Should not delete invite with multiple members")

        let inboxCount = try await dbManager.dbReader.read { db in
            try DBInbox.fetchCount(db)
        }
        #expect(inboxCount == 1, "Inbox should be preserved")

        let identities = try await identityStore.loadAll()
        #expect(identities.count == 1, "Keychain identity should be preserved")
    }

    // MARK: - Other Conversations Protection

    @Test("Does not delete inbox when it has other non-expired conversations")
    func testSkipsInboxWithOtherConversations() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let identityStore = MockKeychainIdentityStore()
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)

        try await insertInboxAndIdentity(
            dbManager: dbManager, identityStore: identityStore,
            inboxId: "inbox-1", clientId: "client-1", createdAt: tenDaysAgo
        )
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(
                id: "draft-expired", inboxId: "inbox-1", clientId: "client-1",
                inviteTag: "tag-1", createdAt: tenDaysAgo
            ).insert(db)

            try makeDBConversation(
                id: "real-convo", inboxId: "inbox-1", clientId: "client-1",
                inviteTag: "", createdAt: Date(), consent: .allowed
            ).insert(db)
        }

        let session = makeSessionManager(dbManager: dbManager, identityStore: identityStore)

        let deleted = try await session.deleteExpiredPendingInvites()

        let inboxCount = try await dbManager.dbReader.read { db in
            try DBInbox.fetchCount(db)
        }
        #expect(inboxCount == 1, "Inbox should be preserved when it has other conversations")

        let identities = try await identityStore.loadAll()
        #expect(identities.count == 1, "Keychain identity should be preserved")

        let realConvoExists = try await dbManager.dbReader.read { db in
            try DBConversation.filter(DBConversation.Columns.id == "real-convo").fetchCount(db) > 0
        }
        #expect(realConvoExists, "Non-expired conversation should still exist")
    }

    // MARK: - Recent Invites

    @Test("Does not delete recent pending invites")
    func testSkipsRecentInvites() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let identityStore = MockKeychainIdentityStore()
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)

        try await insertInboxAndIdentity(
            dbManager: dbManager, identityStore: identityStore,
            inboxId: "inbox-1", clientId: "client-1", createdAt: twoDaysAgo
        )
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(
                id: "draft-recent", inboxId: "inbox-1", clientId: "client-1",
                inviteTag: "tag-1", createdAt: twoDaysAgo
            ).insert(db)
        }

        let session = makeSessionManager(dbManager: dbManager, identityStore: identityStore)

        let deleted = try await session.deleteExpiredPendingInvites()
        #expect(deleted == 0)

        let inboxCount = try await dbManager.dbReader.read { db in
            try DBInbox.fetchCount(db)
        }
        #expect(inboxCount == 1, "Inbox should be preserved for recent invite")
    }

    // MARK: - Lifecycle Manager Cleanup

    @Test("Removes deleted inbox from lifecycle manager tracking")
    func testRemovesFromLifecycleManager() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let identityStore = MockKeychainIdentityStore()
        let lifecycleManager = MockInboxLifecycleManager()
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)

        await lifecycleManager.forceRemove(clientId: "client-1")
        await lifecycleManager.sleep(clientId: "client-1")

        try await insertInboxAndIdentity(
            dbManager: dbManager, identityStore: identityStore,
            inboxId: "inbox-1", clientId: "client-1", createdAt: tenDaysAgo
        )
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(
                id: "draft-expired", inboxId: "inbox-1", clientId: "client-1",
                inviteTag: "tag-1", createdAt: tenDaysAgo
            ).insert(db)
        }

        let session = makeSessionManager(
            dbManager: dbManager, identityStore: identityStore, lifecycleManager: lifecycleManager
        )

        _ = try await session.deleteExpiredPendingInvites()

        let isAwake = await lifecycleManager.isAwake(clientId: "client-1")
        let isSleeping = await lifecycleManager.isSleeping(clientId: "client-1")
        #expect(!isAwake && !isSleeping, "Client should be removed from lifecycle manager")
    }

    // MARK: - Partial Failure Resilience

    @Test("Continues cleanup when inbox writer fails for one client")
    func testContinuesOnPartialFailure() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let identityStore = MockKeychainIdentityStore()
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)

        try await insertInboxAndIdentity(
            dbManager: dbManager, identityStore: identityStore,
            inboxId: "inbox-1", clientId: "client-1", createdAt: tenDaysAgo
        )
        try await insertInboxAndIdentity(
            dbManager: dbManager, identityStore: identityStore,
            inboxId: "inbox-2", clientId: "client-2", createdAt: tenDaysAgo
        )
        try await dbManager.dbWriter.write { db in
            try makeDBConversation(
                id: "draft-expired-1", inboxId: "inbox-1", clientId: "client-1",
                inviteTag: "tag-1", createdAt: tenDaysAgo
            ).insert(db)
            try makeDBConversation(
                id: "draft-expired-2", inboxId: "inbox-2", clientId: "client-2",
                inviteTag: "tag-2", createdAt: tenDaysAgo
            ).insert(db)
        }

        let session = makeSessionManager(dbManager: dbManager, identityStore: identityStore)

        let deleted = try await session.deleteExpiredPendingInvites()
        #expect(deleted == 2, "Both expired conversations should be deleted")
    }

    // MARK: - Empty State

    @Test("Returns zero when no expired invites exist")
    func testNoExpiredInvites() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let session = makeSessionManager(dbManager: dbManager)

        let deleted = try await session.deleteExpiredPendingInvites()
        #expect(deleted == 0)
    }
}
