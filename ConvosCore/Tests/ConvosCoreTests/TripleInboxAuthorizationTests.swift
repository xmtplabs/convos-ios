@preconcurrency @testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

private let testEnvironment = AppEnvironment.tests

/// Tests that reproduce the triple inbox authorization bug from the March 13, 2026
/// "Error accessing the storage" incident.
///
/// The bug: when an inbox ID exists in both the database activity records AND the
/// unused conversation keychain cache, `initializeOnAppLaunch()` and
/// `prepareUnusedConversationIfNeeded()` each independently authorize the same inbox,
/// creating multiple XMTP clients that open the same .db3 file. If one client's
/// InboxStateMachine deletes the database (e.g., after a conversation explosion), the
/// other clients are left with stale references to a deleted file.
///
/// See: docs/investigations/2026-03-13-storage-error-investigation.md
@Suite("Triple Inbox Authorization Bug", .serialized)
struct TripleInboxAuthorizationTests {

    // MARK: - Unit Tests (Mock-based, no Docker)

    @Test("initializeOnAppLaunch wakes an inbox that is also in the unused cache")
    func testInitWakesUnusedInbox() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()
        let mockUnusedCache = SpyUnusedConversationCache()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 10,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedConversationCache: mockUnusedCache
        )

        await mockUnusedCache.setUnusedInboxId("inbox-unused")

        activityRepo.activities = [
            InboxActivity(
                clientId: "client-used",
                inboxId: "inbox-used",
                lastActivity: Date(),
                conversationCount: 1
            ),
            InboxActivity(
                clientId: "client-unused",
                inboxId: "inbox-unused",
                lastActivity: nil,
                conversationCount: 0
            ),
        ]

        await manager.initializeOnAppLaunch()

        let awake = await manager.awakeClientIds
        #expect(
            !awake.contains("client-unused"),
            "initializeOnAppLaunch should not wake an inbox that is in the unused cache"
        )
        #expect(awake.contains("client-used"), "Regular inboxes should still be woken")
    }

    @Test("Full app launch sequence does not create duplicate services for unused inbox")
    func testFullLaunchNoDuplicateServices() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()
        let countingCache = CountingUnusedConversationCache()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 10,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedConversationCache: countingCache
        )

        await countingCache.setUnusedInboxId("inbox-unused")

        activityRepo.activities = [
            InboxActivity(
                clientId: "client-active",
                inboxId: "inbox-active",
                lastActivity: Date(),
                conversationCount: 3
            ),
            InboxActivity(
                clientId: "client-unused",
                inboxId: "inbox-unused",
                lastActivity: nil,
                conversationCount: 0
            ),
        ]

        await manager.initializeOnAppLaunch()
        await manager.prepareUnusedConversationIfNeeded()

        let awake = await manager.awakeClientIds
        let clientIds = Array(awake).sorted()
        let duplicateClientIds = Dictionary(grouping: clientIds, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
        #expect(duplicateClientIds.isEmpty, "No client ID should appear more than once in awake set")

        let wakeCount = await countingCache.wakeCallCount
        let totalServicesForUnused = (awake.contains("client-unused") ? 1 : 0) + wakeCount
        #expect(
            totalServicesForUnused <= 1,
            "The unused inbox should have at most 1 service created for it"
        )
    }

    // MARK: - Integration Test (requires Docker / XMTP node)

    @Test("Real XMTP inbox is not authorized twice when in both DB and unused cache")
    func testRealXMTPInboxNotAuthorizedTwice() async throws {
        let fixtures = TestFixtures()

        let cache = UnusedConversationCache(
            keychainService: fixtures.keychainService,
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

        let unusedConversation = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.isUnused == true)
                .fetchOne(db)
        }
        let unusedInboxId = try #require(unusedConversation?.inboxId)
        let unusedClientId = try #require(unusedConversation?.clientId)

        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)
        try await inboxWriter.save(inboxId: unusedInboxId, clientId: unusedClientId)

        let activityRepo = MockInboxActivityRepository()
        activityRepo.activities = [
            InboxActivity(
                clientId: unusedClientId,
                inboxId: unusedInboxId,
                lastActivity: nil,
                conversationCount: 0
            ),
        ]

        let pendingInviteRepo = MockPendingInviteRepository()
        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 10,
            databaseReader: fixtures.databaseManager.dbReader,
            databaseWriter: fixtures.databaseManager.dbWriter,
            identityStore: fixtures.identityStore,
            environment: testEnvironment,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedConversationCache: cache
        )

        await manager.initializeOnAppLaunch()

        let awakeAfterInit = await manager.awakeClientIds

        await manager.prepareUnusedConversationIfNeeded()

        let awakeAfterPrepare = await manager.awakeClientIds

        let totalServicesCreated = awakeAfterInit.count +
            (await cache.hasUnusedConversation() ? 1 : 0)

        let inboxIdOccurrences = awakeAfterPrepare.filter { clientId in
            clientId == unusedClientId
        }.count

        #expect(
            inboxIdOccurrences <= 1,
            "Unused inbox should only have 1 service after full launch sequence"
        )

        if awakeAfterInit.contains(unusedClientId) {
            let cacheStillHasIt = await cache.hasUnusedConversation()
            #expect(
                !cacheStillHasIt,
                "Cache should be drained if initializeOnAppLaunch woke the unused inbox"
            )
        }

        await cache.clearUnusedFromKeychain()
        await manager.stopAll()
        try? await fixtures.cleanup()
    }

    // MARK: - Helpers

    private func waitForUnusedConversation(
        cache: UnusedConversationCache,
        timeout: Duration = .seconds(15)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await cache.hasUnusedConversation() {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TestTimeoutError()
    }

    private struct TestTimeoutError: Error {}
}

// MARK: - Test Mocks

/// Tracks whether the unused cache was asked about a specific inbox
private actor SpyUnusedConversationCache: UnusedConversationCacheProtocol {
    private var unusedInboxId: String?

    func setUnusedInboxId(_ id: String) {
        unusedInboxId = id
    }

    func prepareUnusedConversationIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {}

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        (service: MockMessagingService(), conversationId: nil)
    }

    func consumeInboxOnly(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        MockMessagingService()
    }

    func clearUnusedFromKeychain() {}

    func isUnusedConversation(_ conversationId: String) -> Bool { false }

    func isUnusedInbox(_ inboxId: String) -> Bool {
        inboxId == unusedInboxId
    }

    func hasUnusedConversation() -> Bool {
        unusedInboxId != nil
    }
}

/// Counts how many times the cache creates/authorizes a service
private actor CountingUnusedConversationCache: UnusedConversationCacheProtocol {
    private var unusedInboxId: String?
    private(set) var wakeCallCount: Int = 0

    func setUnusedInboxId(_ id: String) {
        unusedInboxId = id
    }

    func prepareUnusedConversationIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {
        if unusedInboxId != nil {
            wakeCallCount += 1
        }
    }

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        (service: MockMessagingService(), conversationId: nil)
    }

    func consumeInboxOnly(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        MockMessagingService()
    }

    func clearUnusedFromKeychain() {}

    func isUnusedConversation(_ conversationId: String) -> Bool { false }

    func isUnusedInbox(_ inboxId: String) -> Bool {
        inboxId == unusedInboxId
    }

    func hasUnusedConversation() -> Bool {
        unusedInboxId != nil
    }
}
