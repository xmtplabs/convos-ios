@testable import ConvosCore
import Foundation
import Testing
import XMTPiOS

/// Mock implementation of XMTPStaticOperations for testing
final class MockXMTPStaticOperations: XMTPStaticOperations, @unchecked Sendable {
    // Use nonisolated(unsafe) to silence concurrency warnings for test-only code
    nonisolated(unsafe) static var mockMetadata: [String: MessageMetadata] = [:]
    nonisolated(unsafe) static var getNewestMessageMetadataCalls: [([String], ClientOptions.Api)] = []

    static func getNewestMessageMetadata(
        groupIds: [String],
        api: ClientOptions.Api
    ) async throws -> [String: MessageMetadata] {
        getNewestMessageMetadataCalls.append((groupIds, api))
        return mockMetadata
    }

    static func reset() {
        mockMetadata = [:]
        getNewestMessageMetadataCalls = []
    }
}

/// Helper to create a MessageMetadata for testing
func makeMessageMetadata(createdNs: Int64) -> MessageMetadata {
    // FfiCursor requires originatorId and sequenceId
    let cursor = FfiCursor(originatorId: 0, sequenceId: 0)
    return MessageMetadata(cursor: cursor, createdNs: createdNs)
}

@Suite("SleepingInboxMessageChecker Tests", .serialized)
struct SleepingInboxMessageCheckerTests {

    init() {
        // Reset mock state before each test
        MockXMTPStaticOperations.reset()
    }

    // MARK: - Wake Decision Tests

    @Test("Wakes sleeping inbox when it has newer messages than oldest awake inbox")
    func testWakesSleepingInboxWithNewerMessages() async throws {
        let fixtures = makeTestFixtures()

        // Set up: client-1 is awake with old activity, client-2 is sleeping with newer messages
        let oldDate = Date().addingTimeInterval(-3600) // 1 hour ago
        let newerDateNs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000) // now in nanoseconds

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"]
        ]

        // client-1 is awake, client-2 is sleeping
        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"])

        // Mock XMTP response: conv-2 has a newer message
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: newerDateNs)
        ]

        // Run check
        await fixtures.checker.checkNow()

        // Verify client-2 was woken
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains("client-2"), "Sleeping inbox with newer messages should be woken")
    }

    @Test("Does not wake sleeping inbox when it has older messages than oldest awake inbox")
    func testDoesNotWakeSleepingInboxWithOlderMessages() async throws {
        let fixtures = makeTestFixtures()

        // Set up: client-1 is awake with recent activity, client-2 is sleeping with older messages
        let recentDate = Date() // now
        let olderDateNs: Int64 = Int64(Date().addingTimeInterval(-7200).timeIntervalSince1970 * 1_000_000_000) // 2 hours ago in ns

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: recentDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"]
        ]

        // client-1 is awake, client-2 is sleeping
        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"])

        // Mock XMTP response: conv-2 has an older message
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: olderDateNs)
        ]

        // Run check
        await fixtures.checker.checkNow()

        // Verify client-2 was NOT woken
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(!wokenClientIds.contains("client-2"), "Sleeping inbox with older messages should not be woken")
    }

    @Test("Skips check when no sleeping inboxes exist")
    func testSkipsCheckWhenNoSleepingInboxes() async throws {
        let fixtures = makeTestFixtures()

        // Set up: only awake inboxes
        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
        ]

        // client-1 is awake, no sleeping inboxes
        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: [])

        // Run check
        await fixtures.checker.checkNow()

        // Verify no XMTP calls were made
        #expect(MockXMTPStaticOperations.getNewestMessageMetadataCalls.isEmpty, "Should not call XMTP when no sleeping inboxes")
    }

    @Test("Skips sleeping inboxes with no conversations")
    func testSkipsSleepingInboxesWithNoConversations() async throws {
        let fixtures = makeTestFixtures()

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 0),
        ]

        // client-2 has no conversations
        fixtures.activityRepo.mockConversationIds = [
            "client-2": []
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"])

        // Run check
        await fixtures.checker.checkNow()

        // Verify no XMTP calls were made (no conversation IDs to check)
        #expect(MockXMTPStaticOperations.getNewestMessageMetadataCalls.isEmpty || MockXMTPStaticOperations.getNewestMessageMetadataCalls[0].0.isEmpty,
                "Should not make meaningful XMTP call for inbox with no conversations")
    }

    @Test("Correctly interprets createdNs as nanoseconds")
    func testCreatedNsInterpretation() async throws {
        let fixtures = makeTestFixtures()

        // Set up specific timestamps to verify nanosecond interpretation
        let oldActivityDate = Date(timeIntervalSince1970: 1000) // Unix timestamp 1000
        let newerMessageNs: Int64 = 2000 * 1_000_000_000 // Unix timestamp 2000 in nanoseconds

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldActivityDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"])

        // Mock: conv-2 has message at timestamp 2000 (newer than 1000)
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: newerMessageNs)
        ]

        await fixtures.checker.checkNow()

        // The message at timestamp 2000 should be newer than the oldest awake activity at 1000
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains("client-2"), "Should correctly compare nanosecond timestamps")
    }

    @Test("Finds newest message across multiple conversations in sleeping inbox")
    func testFindsNewestMessageAcrossMultipleConversations() async throws {
        let fixtures = makeTestFixtures()

        let oldAwakeActivity = Date().addingTimeInterval(-1800) // 30 min ago
        let oldMessageNs: Int64 = Int64(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1_000_000_000) // 1 hour ago
        let newestMessageNs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000) // now

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldAwakeActivity, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 2),
        ]

        // client-2 has multiple conversations
        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2a", "conv-2b"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"])

        // conv-2a has old message, conv-2b has newest message
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2a": makeMessageMetadata(createdNs: oldMessageNs),
            "conv-2b": makeMessageMetadata(createdNs: newestMessageNs)
        ]

        await fixtures.checker.checkNow()

        // Should wake because conv-2b has a newer message
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains("client-2"), "Should wake based on newest message across all conversations")
    }

    @Test("Handles multiple sleeping inboxes")
    func testHandlesMultipleSleepingInboxes() async throws {
        let fixtures = makeTestFixtures()

        let oldAwakeActivity = Date().addingTimeInterval(-1800) // 30 min ago
        let newerMessageNs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000) // now
        let olderMessageNs: Int64 = Int64(Date().addingTimeInterval(-7200).timeIntervalSince1970 * 1_000_000_000) // 2 hours ago

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldAwakeActivity, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"],
            "client-3": ["conv-3"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2", "client-3"])

        // client-2 has newer message, client-3 has older message
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: newerMessageNs),
            "conv-3": makeMessageMetadata(createdNs: olderMessageNs)
        ]

        await fixtures.checker.checkNow()

        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains("client-2"), "Should wake client-2 with newer messages")
        #expect(!wokenClientIds.contains("client-3"), "Should not wake client-3 with older messages")
    }

    // MARK: - Test Helpers

    struct TestFixtures {
        let checker: SleepingInboxMessageChecker
        let activityRepo: MockInboxActivityRepository
        let lifecycleManager: TestableInboxLifecycleManager
    }

    func makeTestFixtures() -> TestFixtures {
        let activityRepo = MockInboxActivityRepository()
        let lifecycleManager = TestableInboxLifecycleManager()
        let appLifecycle = MockAppLifecycleProvider(
            didEnterBackgroundNotification: .init("TestBackground"),
            willEnterForegroundNotification: .init("TestForeground"),
            didBecomeActiveNotification: .init("TestActive")
        )

        let checker = SleepingInboxMessageChecker(
            checkInterval: 60,
            environment: .tests,
            activityRepository: activityRepo,
            lifecycleManager: lifecycleManager,
            appLifecycle: appLifecycle,
            xmtpStaticOperations: MockXMTPStaticOperations.self
        )

        return TestFixtures(
            checker: checker,
            activityRepo: activityRepo,
            lifecycleManager: lifecycleManager
        )
    }
}

// MARK: - Testable Lifecycle Manager

/// A testable version of InboxLifecycleManager that tracks wake calls
actor TestableInboxLifecycleManager: InboxLifecycleManagerProtocol {
    let maxAwakeInboxes: Int = 50
    private var _awakeClientIds: Set<String> = []
    private var _sleepingClientIds: Set<String> = []
    private var _wokenClientIds: [String] = []
    private var _activeClientId: String?

    var awakeClientIds: Set<String> { _awakeClientIds }
    var sleepingClientIds: Set<String> { _sleepingClientIds }
    var pendingInviteClientIds: Set<String> { [] }
    var activeClientId: String? { _activeClientId }
    var wokenClientIds: [String] { _wokenClientIds }

    func setActiveClientId(_ clientId: String?) {
        _activeClientId = clientId
    }

    func setAwake(clientIds: Set<String>) {
        _awakeClientIds = clientIds
    }

    func setSleeping(clientIds: Set<String>) {
        _sleepingClientIds = clientIds
    }

    func wake(clientId: String, inboxId: String, reason: WakeReason) async throws -> any MessagingServiceProtocol {
        _wokenClientIds.append(clientId)
        _awakeClientIds.insert(clientId)
        _sleepingClientIds.remove(clientId)
        throw InboxLifecycleError.inboxNotFound(clientId: clientId) // We don't need real service for tests
    }

    func sleep(clientId: String) async {
        _awakeClientIds.remove(clientId)
        _sleepingClientIds.insert(clientId)
    }

    func forceRemove(clientId: String) async {
        _awakeClientIds.remove(clientId)
        _sleepingClientIds.remove(clientId)
    }

    func getOrCreateService(clientId: String, inboxId: String) -> any MessagingServiceProtocol {
        MockMessagingService()
    }

    func getOrWake(clientId: String, inboxId: String) async throws -> any MessagingServiceProtocol {
        try await wake(clientId: clientId, inboxId: inboxId, reason: .userInteraction)
    }

    func isAwake(clientId: String) -> Bool {
        _awakeClientIds.contains(clientId)
    }

    func isSleeping(clientId: String) -> Bool {
        _sleepingClientIds.contains(clientId)
    }

    func rebalance() async {}

    func initializeOnAppLaunch() async {}

    func stopAll() async {
        _awakeClientIds.removeAll()
        _sleepingClientIds.removeAll()
    }

    func createNewInbox() async -> any MessagingServiceProtocol {
        fatalError("Not implemented for tests")
    }

    func prepareUnusedInboxIfNeeded() async {}

    func clearUnusedInbox() async {}
}
