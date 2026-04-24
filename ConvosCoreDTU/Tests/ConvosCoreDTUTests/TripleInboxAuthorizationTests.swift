@testable import ConvosCore
import Foundation
import GRDB
import XCTest

/// Phase 2 batch 4: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/TripleInboxAuthorizationTests.swift`.
///
/// Reproduces the triple-inbox-authorization bug from the March 13, 2026
/// "Error accessing the storage" incident. The original suite mixed two
/// flavours:
///
///  - **Unit tests** (tests 1 & 2): exercise `InboxLifecycleManager`
///    against purely-mock dependencies (no Docker, no XMTP). These are
///    backend-agnostic and run on both lanes.
///  - **Integration test** (test 3): drives a real XMTP client through
///    `UnusedConversationCache` + `InboxLifecycleManager.initializeOnAppLaunch`.
///    `UnusedConversationCache` only knows how to authorize inboxes
///    through the XMTPiOS `MessagingClientFactory` path; DTU has no
///    equivalent today (the unused-conversation cache hasn't been
///    adapter-migrated). Skip on DTU, keep the XMTPiOS lane covered.
final class TripleInboxAuthorizationTests: XCTestCase {
    // MARK: - Lifecycle

    private var fixtures: DualBackendTestFixtures?

    override func tearDown() async throws {
        if let fixtures {
            try? await fixtures.cleanup()
            self.fixtures = nil
        }
        try await super.tearDown()
    }

    override class func tearDown() {
        Task {
            await DualBackendTestFixtures.tearDownSharedDTUIfNeeded()
        }
        super.tearDown()
    }

    /// XMTPiOS backend requires the Docker-backed XMTP node. Skip the
    /// run cleanly instead of flaking when the env var isn't set.
    private func guardBackendReady(_ backend: DualBackendTestFixtures.Backend) throws {
        if backend == .xmtpiOS,
           ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] == nil {
            throw XCTSkip(
                "CONVOS_MESSAGING_BACKEND=\(backend.rawValue) (default) and "
                    + "XMTP_NODE_ADDRESS is unset; skipping to avoid a network-"
                    + "dependent failure. Start the XMTP Docker stack or set "
                    + "CONVOS_MESSAGING_BACKEND=dtu."
            )
        }
    }

    // MARK: - Unit Tests (Mock-based, no Docker / no DTU server)

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
        XCTAssertFalse(
            awake.contains("client-unused"),
            "initializeOnAppLaunch should not wake an inbox that is in the unused cache"
        )
        XCTAssertTrue(awake.contains("client-used"), "Regular inboxes should still be woken")
    }

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
        XCTAssertTrue(duplicateClientIds.isEmpty, "No client ID should appear more than once in awake set")

        let wakeCount = await countingCache.wakeCallCount
        let totalServicesForUnused = (awake.contains("client-unused") ? 1 : 0) + wakeCount
        XCTAssertLessThanOrEqual(
            totalServicesForUnused,
            1,
            "The unused inbox should have at most 1 service created for it"
        )
    }

    // MARK: - Integration Test (requires Docker / XMTP node, XMTPiOS-only)

    func testRealXMTPInboxNotAuthorizedTwice() async throws {
        let backend = DualBackendTestFixtures.Backend.selected
        try guardBackendReady(backend)
        if backend == .dtu {
            // `UnusedConversationCache.prepareUnusedConversationIfNeeded`
            // reaches into the XMTPiOS-specific
            // `AuthorizeInboxOperation` / `MessagingService`
            // construction path. DTU has no equivalent — the unused-
            // inbox cache hasn't been adapter-migrated. Skip on DTU
            // until that work lands.
            throw XCTSkip(
                "[dtu] UnusedConversationCache is XMTPiOS-only; DTU has no "
                    + "equivalent for unused inbox authorisation yet"
            )
        }

        let fixture = DualBackendTestFixtures(
            backend: backend,
            aliasPrefix: "triple-inbox"
        )
        self.fixtures = fixture

        // The XMTPiOS-path of UnusedConversationCache needs a
        // KeychainService. DualBackendTestFixtures doesn't own one
        // (DTU has no keychain) — spin one up locally for the XMTPiOS
        // lane only. The `@testable` import reaches the internal
        // MockKeychainService.
        let keychainService = MockKeychainService()

        let cache = UnusedConversationCache(
            keychainService: keychainService,
            identityStore: fixture.identityStore,
            platformProviders: .mock
        )

        await cache.clearUnusedFromKeychain()
        await cache.prepareUnusedConversationIfNeeded(
            databaseWriter: fixture.databaseManager.dbWriter,
            databaseReader: fixture.databaseManager.dbReader,
            environment: .tests
        )

        try await waitForUnusedConversation(cache: cache)

        let unusedConversation = try await fixture.databaseManager.dbReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.isUnused == true)
                .fetchOne(db)
        }
        let unusedInboxId = try XCTUnwrap(unusedConversation?.inboxId)
        let unusedClientId = try XCTUnwrap(unusedConversation?.clientId)

        let inboxWriter = InboxWriter(dbWriter: fixture.databaseManager.dbWriter)
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
            databaseReader: fixture.databaseManager.dbReader,
            databaseWriter: fixture.databaseManager.dbWriter,
            identityStore: fixture.identityStore,
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedConversationCache: cache
        )

        await manager.initializeOnAppLaunch()

        let awakeAfterInit = await manager.awakeClientIds

        await manager.prepareUnusedConversationIfNeeded()

        let awakeAfterPrepare = await manager.awakeClientIds

        let inboxIdOccurrences = awakeAfterPrepare.filter { clientId in
            clientId == unusedClientId
        }.count

        XCTAssertLessThanOrEqual(
            inboxIdOccurrences,
            1,
            "Unused inbox should only have 1 service after full launch sequence"
        )

        if awakeAfterInit.contains(unusedClientId) {
            let cacheStillHasIt = await cache.hasUnusedConversation()
            XCTAssertFalse(
                cacheStillHasIt,
                "Cache should be drained if initializeOnAppLaunch woke the unused inbox"
            )
        }

        await cache.clearUnusedFromKeychain()
        await manager.stopAll()
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
