@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("SessionManager Tests", .serialized)
struct SessionManagerTests {

    private enum TestError: Error {
        case timeout(String)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        interval: Duration = .milliseconds(10),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: interval)
        }
        throw TestError.timeout("Condition not met within \(timeout)")
    }

    // MARK: - Wake Inbox by Conversation ID Tests

    @Test("wakeInboxForNotification wakes sleeping client by conversation ID")
    func testWakeInboxByConversationId() async throws {
        let fixtures = try await makeTestFixtures()

        // Insert an inbox and conversation into the database
        let clientId = "test-client-id"
        let inboxId = "test-inbox-id"
        let conversationId = "test-conversation-id"

        try await fixtures.databaseManager.dbWriter.write { db in
            // Insert inbox
            try DBInbox(
                inboxId: inboxId,
                clientId: clientId,
                createdAt: Date()
            ).insert(db)

            // Insert conversation associated with the inbox
            try DBConversation(
                id: conversationId,
                inboxId: inboxId,
                clientId: clientId,
                clientConversationId: "xmtp-convo-id",
                inviteTag: "",
                creatorId: "",
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Test Conversation",
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeImageInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty
            ).insert(db)
        }

        // Set up mock activity for the lifecycle manager
        fixtures.activityRepo.activities = [
            InboxActivity(clientId: clientId, inboxId: inboxId, lastActivity: Date(), conversationCount: 1)
        ]

        // Verify the inbox starts as not awake
        let initiallyAwake = await fixtures.lifecycleManager.isAwake(clientId: clientId)
        #expect(!initiallyAwake, "Inbox should not be awake initially")

        // Wake the inbox using the conversation ID
        await fixtures.sessionManager.wakeInboxForNotification(conversationId: conversationId)

        // Verify the inbox is now awake
        let isAwakeAfter = await fixtures.lifecycleManager.isAwake(clientId: clientId)
        #expect(isAwakeAfter, "Inbox should be awake after wakeInboxForNotification")
    }

    @Test("wakeInboxForNotification handles missing conversation gracefully")
    func testWakeInboxWithMissingConversation() async throws {
        let fixtures = try await makeTestFixtures()

        // Try to wake with a non-existent conversation ID - should not crash
        await fixtures.sessionManager.wakeInboxForNotification(conversationId: "non-existent-conversation")

        // Just verify it completes without error
        #expect(await fixtures.lifecycleManager.awakeClientIds.isEmpty, "No inbox should be awake for missing conversation")
    }

    // MARK: - shouldDisplayNotification Tests

    @Test("shouldDisplayNotification returns true when no active client")
    func testShouldDisplayNotificationWhenNoActiveClient() async throws {
        let fixtures = try await makeTestFixtures()

        // Insert an inbox and conversation
        let clientId = "test-client"
        let inboxId = "test-inbox"
        let conversationId = "test-conversation"

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxId, clientId: clientId, createdAt: Date()).insert(db)
            try DBConversation(
                id: conversationId,
                inboxId: inboxId,
                clientId: clientId,
                clientConversationId: "xmtp-convo",
                inviteTag: "",
                creatorId: "",
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Test",
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeImageInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty
            ).insert(db)
        }

        // No active client set - should show all notifications
        let shouldDisplay = await fixtures.sessionManager.shouldDisplayNotification(for: conversationId)
        #expect(shouldDisplay, "Should display notification when no active client")
    }

    @Test("shouldDisplayNotification returns false for conversation in active inbox")
    func testShouldDisplayNotificationSuppressesActiveInbox() async throws {
        let fixtures = try await makeTestFixtures()

        let clientId = "test-client"
        let inboxId = "test-inbox"
        let conversationId = "test-conversation"

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxId, clientId: clientId, createdAt: Date()).insert(db)
            try DBConversation(
                id: conversationId,
                inboxId: inboxId,
                clientId: clientId,
                clientConversationId: "xmtp-convo",
                inviteTag: "",
                creatorId: "",
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Test",
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeImageInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty
            ).insert(db)
        }

        // Set the active client ID (simulating user viewing a conversation in this inbox)
        await fixtures.lifecycleManager.setActiveClientId(clientId)

        // Notification for conversation in active inbox should be suppressed
        let shouldDisplay = await fixtures.sessionManager.shouldDisplayNotification(for: conversationId)
        #expect(!shouldDisplay, "Should suppress notification for conversation in active inbox")
    }

    @Test("shouldDisplayNotification returns true for conversation in different inbox")
    func testShouldDisplayNotificationAllowsDifferentInbox() async throws {
        let fixtures = try await makeTestFixtures()

        let clientId1 = "client-1"
        let inboxId1 = "inbox-1"
        let conversationId1 = "conversation-1"

        let clientId2 = "client-2"
        let inboxId2 = "inbox-2"
        let conversationId2 = "conversation-2"

        try await fixtures.databaseManager.dbWriter.write { db in
            // Insert first inbox and conversation
            try DBInbox(inboxId: inboxId1, clientId: clientId1, createdAt: Date()).insert(db)
            try DBConversation(
                id: conversationId1,
                inboxId: inboxId1,
                clientId: clientId1,
                clientConversationId: "xmtp-1",
                inviteTag: "tag-1",
                creatorId: "",
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Conversation 1",
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeImageInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty
            ).insert(db)

            // Insert second inbox and conversation
            try DBInbox(inboxId: inboxId2, clientId: clientId2, createdAt: Date()).insert(db)
            try DBConversation(
                id: conversationId2,
                inboxId: inboxId2,
                clientId: clientId2,
                clientConversationId: "xmtp-2",
                inviteTag: "tag-2",
                creatorId: "",
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Conversation 2",
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeImageInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty
            ).insert(db)
        }

        // Set client-1 as active
        await fixtures.lifecycleManager.setActiveClientId(clientId1)

        // Notification for conversation in client-2's inbox should show
        let shouldDisplay = await fixtures.sessionManager.shouldDisplayNotification(for: conversationId2)
        #expect(shouldDisplay, "Should display notification for conversation in different inbox")
    }

    // MARK: - Wake Inbox by Conversation ID Tests

    @Test("wakeInboxForNotification wakes correct client when multiple exist")
    func testWakeCorrectClientAmongMultiple() async throws {
        let fixtures = try await makeTestFixtures()

        // Use unique IDs to avoid cross-test interference
        let testId = UUID().uuidString.prefix(8)
        let clientId1 = "wake-test-client1-\(testId)"
        let inboxId1 = "wake-test-inbox1-\(testId)"
        let conversationId1 = "wake-test-conv1-\(testId)"

        let clientId2 = "wake-test-client2-\(testId)"
        let inboxId2 = "wake-test-inbox2-\(testId)"
        let conversationId2 = "wake-test-conv2-\(testId)"

        try await fixtures.databaseManager.dbWriter.write { db in
            // Insert first inbox and conversation
            try DBInbox(inboxId: inboxId1, clientId: clientId1, createdAt: Date()).insert(db)
            try DBConversation(
                id: conversationId1,
                inboxId: inboxId1,
                clientId: clientId1,
                clientConversationId: "xmtp-1",
                inviteTag: "tag-1",
                creatorId: "",
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Conversation 1",
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeImageInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty
            ).insert(db)

            // Insert second inbox and conversation
            try DBInbox(inboxId: inboxId2, clientId: clientId2, createdAt: Date()).insert(db)
            try DBConversation(
                id: conversationId2,
                inboxId: inboxId2,
                clientId: clientId2,
                clientConversationId: "xmtp-2",
                inviteTag: "tag-2",
                creatorId: "",
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Conversation 2",
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeImageInPublicPreview: false,
                expiresAt: nil,
                debugInfo: .empty
            ).insert(db)
        }

        // Set up mock activity for both clients
        fixtures.activityRepo.activities = [
            InboxActivity(clientId: clientId1, inboxId: inboxId1, lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: clientId2, inboxId: inboxId2, lastActivity: Date(), conversationCount: 1),
        ]

        // Ensure clean starting state - both inboxes should be asleep
        if await fixtures.lifecycleManager.isAwake(clientId: clientId1) {
            await fixtures.lifecycleManager.sleep(clientId: clientId1)
        }
        if await fixtures.lifecycleManager.isAwake(clientId: clientId2) {
            await fixtures.lifecycleManager.sleep(clientId: clientId2)
        }

        // Verify both are asleep before starting
        let client1InitiallyAwake = await fixtures.lifecycleManager.isAwake(clientId: clientId1)
        let client2InitiallyAwake = await fixtures.lifecycleManager.isAwake(clientId: clientId2)
        #expect(!client1InitiallyAwake, "Client 1 should start asleep")
        #expect(!client2InitiallyAwake, "Client 2 should start asleep")

        // Wake the second inbox using its conversation ID
        await fixtures.sessionManager.wakeInboxForNotification(conversationId: conversationId2)

        // Wait for wake operation to complete with polling
        try await waitUntil {
            await fixtures.lifecycleManager.isAwake(clientId: clientId2)
        }

        // Verify only the second inbox is awake
        let client1Awake = await fixtures.lifecycleManager.isAwake(clientId: clientId1)
        let client2Awake = await fixtures.lifecycleManager.isAwake(clientId: clientId2)

        #expect(!client1Awake, "Client 1 should not be awake")
        #expect(client2Awake, "Client 2 should be awake after waking by its conversation ID")
    }

    // MARK: - Test Helpers

    struct TestFixtures {
        let sessionManager: SessionManager
        let lifecycleManager: InboxLifecycleManager
        let activityRepo: MockInboxActivityRepository
        let databaseManager: MockDatabaseManager
    }

    func makeTestFixtures() async throws -> TestFixtures {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()

        let lifecycleManager = InboxLifecycleManager(
            maxAwakeInboxes: 50,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo
        )

        let sessionManager = SessionManager(
            databaseWriter: databaseManager.dbWriter,
            databaseReader: databaseManager.dbReader,
            environment: .tests,
            identityStore: MockKeychainIdentityStore(),
            lifecycleManager: lifecycleManager,
            platformProviders: .mock
        )

        return TestFixtures(
            sessionManager: sessionManager,
            lifecycleManager: lifecycleManager,
            activityRepo: activityRepo,
            databaseManager: databaseManager
        )
    }
}
