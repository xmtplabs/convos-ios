@preconcurrency @testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

private let testEnvironment = AppEnvironment.tests

@Suite("ConsumeInboxOnly Tests")
struct ConsumeInboxOnlyTests {
    private enum TestError: Error {
        case timeout(String)
    }

    private func waitForUnusedConversation(
        cache: UnusedConversationCache,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await cache.hasUnusedConversation() {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TestError.timeout("Timed out waiting for unused conversation to be created")
    }

    // MARK: - consumeInboxOnly returns a valid service

    @Test("consumeInboxOnly returns a valid messaging service")
    func testConsumeInboxOnlyReturnsValidService() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        let service = await cache.consumeInboxOnly(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let result = try await service.inboxStateManager.waitForInboxReadyResult()
        #expect(result.client.inboxId.isEmpty == false)

        await service.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - consumeInboxOnly cleans up orphaned conversation

    @Test("consumeInboxOnly leaves the pre-created conversation as unused in database")
    func testConsumeInboxOnlyLeavesConversationAsUnused() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        let unusedCountBefore = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.filter(DBConversation.Columns.isUnused == true).fetchCount(db)
        }
        #expect(unusedCountBefore == 1, "Should have 1 unused conversation before consuming inbox-only")

        let service = await cache.consumeInboxOnly(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let unusedCountAfter = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.filter(DBConversation.Columns.isUnused == true).fetchCount(db)
        }
        #expect(unusedCountAfter == 1, "Unused conversation should remain in database to prevent re-sync race condition")

        await service.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - consumeInboxOnly does not create a visible conversation

    @Test("consumeInboxOnly does not make any conversation visible in the list")
    func testConsumeInboxOnlyNoVisibleConversation() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        let service = await cache.consumeInboxOnly(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let visibleConversations = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.isUnused == false)
                .filter(!DBConversation.Columns.id.like("draft-%"))
                .fetchCount(db)
        }
        #expect(visibleConversations == 0, "No conversation should be visible in the list after consumeInboxOnly")

        await service.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - consumeInboxOnly clears keychain

    @Test("consumeInboxOnly clears both inbox and conversation from keychain")
    func testConsumeInboxOnlyClearsKeychain() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        let service = await cache.consumeInboxOnly(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let result = try await service.inboxStateManager.waitForInboxReadyResult()
        let inboxId = result.client.inboxId

        let isStillUnusedInbox = await cache.isUnusedInbox(inboxId)
        #expect(!isStillUnusedInbox, "Consumed inbox should not be marked as unused in keychain")

        let hasUnused = await cache.hasUnusedConversation()
        #expect(!hasUnused, "No unused conversation should remain after consumeInboxOnly")

        await service.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - consumeInboxOnly returns different inbox than consumeOrCreate

    @Test("consumeInboxOnly and consumeOrCreate return different services")
    func testConsumeInboxOnlyReturnsDifferentService() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        let service1 = await cache.consumeInboxOnly(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        let result1 = try await service1.inboxStateManager.waitForInboxReadyResult()

        let (service2, _) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        let result2 = try await service2.inboxStateManager.waitForInboxReadyResult()

        #expect(
            result1.client.inboxId != result2.client.inboxId,
            "consumeInboxOnly and consumeOrCreate should return different inboxes"
        )

        await service1.stopAndDelete()
        await service2.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - consumeInboxOnly without pre-created conversation falls back to fresh

    @Test("consumeInboxOnly works when no cached conversation exists")
    func testConsumeInboxOnlyWithoutCache() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()

        let service = await cache.consumeInboxOnly(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        let result = try await service.inboxStateManager.waitForInboxReadyResult()
        #expect(result.client.inboxId.isEmpty == false, "Should create a fresh inbox when no cache available")

        await service.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - consumeInboxOnly triggers background replenishment

    @Test("consumeInboxOnly schedules background creation of new unused conversation")
    func testConsumeInboxOnlyTriggersReplenishment() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        let service = await cache.consumeInboxOnly(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        try await waitForUnusedConversation(cache: cache, timeout: .seconds(15))
        let hasNewUnused = await cache.hasUnusedConversation()
        #expect(hasNewUnused, "Background task should have created a new unused conversation after consumeInboxOnly")

        await service.stopAndDelete()
        try? await fixtures.cleanup()
    }

    // MARK: - Contrast: consumeOrCreate DOES make conversation visible

    @Test("consumeOrCreate makes the conversation visible (contrast with consumeInboxOnly)")
    func testConsumeOrCreateMakesConversationVisible() async throws {
        let fixtures = TestFixtures()
        let cache = UnusedConversationCache(
            keychainService: MockKeychainService(),
            identityStore: fixtures.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )
        try await waitForUnusedConversation(cache: cache)

        let (service, conversationId) = await cache.consumeOrCreateMessagingService(
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            environment: testEnvironment
        )

        #expect(conversationId != nil, "consumeOrCreate should return a conversation ID")

        let visibleConversations = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.isUnused == false)
                .filter(!DBConversation.Columns.id.like("draft-%"))
                .fetchCount(db)
        }
        #expect(visibleConversations == 1, "consumeOrCreate should make exactly 1 conversation visible")

        await service.stopAndDelete()
        try? await fixtures.cleanup()
    }
}

// MARK: - InboxLifecycleManager createNewInboxOnly Tests

@Suite("InboxLifecycleManager createNewInboxOnly Tests")
struct InboxLifecycleManagerCreateNewInboxOnlyTests {
    @Test("createNewInboxOnly registers inbox as awake and active")
    func testCreateNewInboxOnlyRegistersInbox() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()
        let mockUnusedCache = SequentialMockUnusedConversationCache()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 50,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedConversationCache: mockUnusedCache
        )

        let service = await manager.createNewInboxOnly()
        let clientId = service.clientId

        #expect(await manager.isAwake(clientId: clientId), "Inbox-only service should be registered as awake")
        #expect(await manager.activeClientId == clientId, "Inbox-only service should be set as active")
        #expect(await manager.awakeClientIds.count == 1, "Should have exactly 1 awake inbox")
    }

    @Test("createNewInboxOnly evicts LRU when at capacity")
    func testCreateNewInboxOnlyEvictsAtCapacity() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()
        let mockUnusedCache = SimpleMockUnusedConversationCache()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 2,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedConversationCache: mockUnusedCache
        )

        let oldDate = Date().addingTimeInterval(-3600)
        let recentDate = Date().addingTimeInterval(-60)
        activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: recentDate, conversationCount: 1),
        ]

        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .appLaunch)
        #expect(await manager.awakeClientIds.count == 2)

        let service = await manager.createNewInboxOnly()
        let newClientId = service.clientId

        #expect(await manager.isAwake(clientId: newClientId), "New inbox-only should be awake")
        #expect(await manager.isSleeping(clientId: "client-1"), "Oldest inbox should have been evicted")
        #expect(await manager.isAwake(clientId: "client-2"), "Recent inbox should still be awake")
    }

    @Test("createNewInboxOnly and createNewInbox return different services")
    func testCreateNewInboxOnlyAndCreateNewInboxDiffer() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()
        let mockUnusedCache = SequentialMockUnusedConversationCache()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 50,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedConversationCache: mockUnusedCache
        )

        let inboxOnlyService = await manager.createNewInboxOnly()
        let inboxOnlyClientId = inboxOnlyService.clientId

        let (fullService, conversationId) = await manager.createNewInbox()
        let fullClientId = fullService.clientId

        #expect(inboxOnlyClientId != fullClientId, "Inbox-only and full inbox should have different client IDs")
        #expect(await manager.isAwake(clientId: inboxOnlyClientId))
        #expect(await manager.isAwake(clientId: fullClientId))
    }
}
