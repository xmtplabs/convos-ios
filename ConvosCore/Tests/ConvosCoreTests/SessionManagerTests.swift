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
                debugInfo: .empty,
                isLocked: false
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
                debugInfo: .empty,
                isLocked: false
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
                debugInfo: .empty,
                isLocked: false
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
                debugInfo: .empty,
                isLocked: false
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
                debugInfo: .empty,
                isLocked: false
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
                debugInfo: .empty,
                isLocked: false
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
                debugInfo: .empty,
                isLocked: false
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

    // MARK: - Create-Delete-Create Scenario Tests

    @Test("Creating inbox after deleting previous one works correctly with SleepingInboxMessageChecker")
    func testCreateDeleteWaitCreateScenario() async throws {
        // This test reproduces the scenario where:
        // 1. User creates a new inbox
        // 2. User deletes that inbox
        // 3. SleepingInboxMessageChecker runs (5 second interval)
        // 4. User tries to create another inbox
        //
        // The issue was that after deletion, something in the state would cause
        // the second inbox creation to fail or behave incorrectly.

        let fixtures = try await makeIntegrationTestFixtures()

        // Step 1: Create the first inbox
        let service1 = await fixtures.sessionManager.addInbox()
        let result1 = try await service1.inboxStateManager.waitForInboxReadyResult()
        let inboxId1 = result1.client.inboxId
        let clientId1 = service1.clientId

        #expect(!inboxId1.isEmpty, "First inbox should have a valid inbox ID")
        #expect(!clientId1.isEmpty, "First inbox should have a valid client ID")

        // Verify inbox is awake
        let isAwake1 = await fixtures.lifecycleManager.isAwake(clientId: clientId1)
        #expect(isAwake1, "First inbox should be awake after creation")

        // Step 2: Delete the first inbox
        try await fixtures.sessionManager.deleteInbox(clientId: clientId1, inboxId: inboxId1)

        // Verify inbox is removed from tracking
        let isAwakeAfterDelete = await fixtures.lifecycleManager.isAwake(clientId: clientId1)
        let isSleepingAfterDelete = await fixtures.lifecycleManager.isSleeping(clientId: clientId1)
        #expect(!isAwakeAfterDelete, "Deleted inbox should not be awake")
        #expect(!isSleepingAfterDelete, "Deleted inbox should not be sleeping")

        // Step 3: Wait for the SleepingInboxMessageChecker interval (5 seconds) plus buffer
        try await Task.sleep(for: .seconds(6))

        // Step 4: Create a second inbox
        let service2 = await fixtures.sessionManager.addInbox()
        let result2 = try await service2.inboxStateManager.waitForInboxReadyResult()
        let inboxId2 = result2.client.inboxId
        let clientId2 = service2.clientId

        #expect(!inboxId2.isEmpty, "Second inbox should have a valid inbox ID")
        #expect(!clientId2.isEmpty, "Second inbox should have a valid client ID")
        #expect(inboxId2 != inboxId1, "Second inbox should have a different inbox ID than the deleted one")

        // Verify second inbox is awake
        let isAwake2 = await fixtures.lifecycleManager.isAwake(clientId: clientId2)
        #expect(isAwake2, "Second inbox should be awake after creation")

        // Clean up
        await service2.stopAndDelete()
        try? await fixtures.cleanup()
    }

    @Test("Multiple create-delete-create cycles with SleepingInboxMessageChecker running")
    func testMultipleCreateDeleteCyclesWithChecker() async throws {
        let fixtures = try await makeIntegrationTestFixtures()

        var previousInboxIds: Set<String> = []

        for cycle in 1...3 {
            // Create inbox
            let service = await fixtures.sessionManager.addInbox()
            let result = try await service.inboxStateManager.waitForInboxReadyResult()
            let inboxId = result.client.inboxId
            let clientId = service.clientId

            #expect(!inboxId.isEmpty, "Cycle \(cycle): Inbox should have a valid inbox ID")
            #expect(!previousInboxIds.contains(inboxId), "Cycle \(cycle): Inbox ID should be unique")
            previousInboxIds.insert(inboxId)

            // Verify inbox is awake
            let isAwake = await fixtures.lifecycleManager.isAwake(clientId: clientId)
            #expect(isAwake, "Cycle \(cycle): Inbox should be awake after creation")

            // Delete the inbox
            try await fixtures.sessionManager.deleteInbox(clientId: clientId, inboxId: inboxId)

            // Wait for SleepingInboxMessageChecker to run
            try await Task.sleep(for: .seconds(6))

            // Verify inbox is fully removed
            let isAwakeAfterDelete = await fixtures.lifecycleManager.isAwake(clientId: clientId)
            let isSleepingAfterDelete = await fixtures.lifecycleManager.isSleeping(clientId: clientId)
            #expect(!isAwakeAfterDelete, "Cycle \(cycle): Deleted inbox should not be awake")
            #expect(!isSleepingAfterDelete, "Cycle \(cycle): Deleted inbox should not be sleeping")
        }

        #expect(previousInboxIds.count == 3, "Should have created 3 unique inboxes")

        try? await fixtures.cleanup()
    }

    @Test("Create-delete-create with maxAwakeInboxes=1 triggers eviction logic")
    func testCreateDeleteCreateWithSingleMaxAwakeInbox() async throws {
        // This test uses maxAwakeInboxes=1 to stress-test the eviction and lifecycle logic.
        // With only 1 allowed awake inbox, every new inbox creation triggers capacity checks.
        let fixtures = try await makeIntegrationTestFixtures(maxAwakeInboxes: 1)

        // Step 1: Create first inbox, wait for ready
        let service1 = await fixtures.sessionManager.addInbox()
        let result1 = try await service1.inboxStateManager.waitForInboxReadyResult()
        let inboxId1 = result1.client.inboxId
        let clientId1 = service1.clientId

        #expect(!inboxId1.isEmpty, "First inbox should have a valid inbox ID")
        let isAwake1 = await fixtures.lifecycleManager.isAwake(clientId: clientId1)
        #expect(isAwake1, "First inbox should be awake")

        // Step 2: Create second inbox (this should trigger eviction logic since maxAwake=1)
        let service2 = await fixtures.sessionManager.addInbox()
        let result2 = try await service2.inboxStateManager.waitForInboxReadyResult()
        let inboxId2 = result2.client.inboxId
        let clientId2 = service2.clientId

        #expect(!inboxId2.isEmpty, "Second inbox should have a valid inbox ID")
        #expect(inboxId2 != inboxId1, "Second inbox should be different from first")

        // Second inbox should be awake (it's the active one after creation)
        let isAwake2 = await fixtures.lifecycleManager.isAwake(clientId: clientId2)
        #expect(isAwake2, "Second inbox should be awake")

        // Step 3: Delete the second inbox
        try await fixtures.sessionManager.deleteInbox(clientId: clientId2, inboxId: inboxId2)

        // Verify second inbox is removed
        let isAwake2AfterDelete = await fixtures.lifecycleManager.isAwake(clientId: clientId2)
        let isSleeping2AfterDelete = await fixtures.lifecycleManager.isSleeping(clientId: clientId2)
        #expect(!isAwake2AfterDelete, "Deleted inbox should not be awake")
        #expect(!isSleeping2AfterDelete, "Deleted inbox should not be sleeping")

        // Step 4: Wait for SleepingInboxMessageChecker interval (5 seconds) plus buffer
        try await Task.sleep(for: .seconds(6))

        // Step 5: Create a third inbox
        let service3 = await fixtures.sessionManager.addInbox()
        let result3 = try await service3.inboxStateManager.waitForInboxReadyResult()
        let inboxId3 = result3.client.inboxId
        let clientId3 = service3.clientId

        #expect(!inboxId3.isEmpty, "Third inbox should have a valid inbox ID")
        #expect(inboxId3 != inboxId1, "Third inbox should be different from first")
        #expect(inboxId3 != inboxId2, "Third inbox should be different from second (deleted)")

        // Third inbox should be awake
        let isAwake3 = await fixtures.lifecycleManager.isAwake(clientId: clientId3)
        #expect(isAwake3, "Third inbox should be awake after creation")

        // Clean up
        await service1.stopAndDelete()
        await service3.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - Test Helpers

    struct TestFixtures {
        let sessionManager: SessionManager
        let lifecycleManager: InboxLifecycleManager
        let activityRepo: MockInboxActivityRepository
        let databaseManager: MockDatabaseManager
    }

    struct IntegrationTestFixtures {
        let sessionManager: SessionManager
        let lifecycleManager: InboxLifecycleManager
        let databaseManager: MockDatabaseManager
        let identityStore: MockKeychainIdentityStore

        func cleanup() async throws {
            try await identityStore.deleteAll()
            try databaseManager.erase()
        }
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

    func makeIntegrationTestFixtures(maxAwakeInboxes: Int = 50) async throws -> IntegrationTestFixtures {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let identityStore = MockKeychainIdentityStore()

        // Use real repositories that query the database
        let activityRepo = InboxActivityRepository(databaseReader: databaseManager.dbReader)
        let pendingInviteRepo = PendingInviteRepository(databaseReader: databaseManager.dbReader)

        let lifecycleManager = InboxLifecycleManager(
            maxAwakeInboxes: maxAwakeInboxes,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: identityStore,
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo
        )

        // Create SleepingInboxMessageChecker with the real activity repository
        let sleepingInboxChecker = SleepingInboxMessageChecker(
            checkInterval: 5,
            environment: .tests,
            activityRepository: activityRepo,
            lifecycleManager: lifecycleManager,
            appLifecycle: PlatformProviders.mock.appLifecycle
        )

        let sessionManager = SessionManager(
            databaseWriter: databaseManager.dbWriter,
            databaseReader: databaseManager.dbReader,
            environment: .tests,
            identityStore: identityStore,
            lifecycleManager: lifecycleManager,
            sleepingInboxChecker: sleepingInboxChecker,
            platformProviders: .mock
        )

        return IntegrationTestFixtures(
            sessionManager: sessionManager,
            lifecycleManager: lifecycleManager,
            databaseManager: databaseManager,
            identityStore: identityStore
        )
    }
}
