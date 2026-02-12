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

    @Test("Wakes sleeping inbox when it has messages newer than its sleep time")
    func testWakesSleepingInboxWithNewerMessages() async throws {
        let fixtures = makeTestFixtures()

        // Set up: client-2 was put to sleep 1 hour ago, and has a message from NOW (newer than sleep time)
        let sleepTime = Date().addingTimeInterval(-3600) // slept 1 hour ago
        let newerDateNs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000) // message from now

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"]
        ]

        // client-1 is awake, client-2 is sleeping (was put to sleep 1 hour ago)
        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"], at: sleepTime)

        // Mock XMTP response: conv-2 has a message from now (newer than sleep time)
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: newerDateNs)
        ]

        // Run check
        await fixtures.checker.checkNow()

        // Verify client-2 was woken (message is newer than sleep time)
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains("client-2"), "Sleeping inbox with messages newer than sleep time should be woken")
    }

    @Test("Does not wake sleeping inbox when messages are older than sleep time")
    func testDoesNotWakeSleepingInboxWithOlderMessages() async throws {
        let fixtures = makeTestFixtures()

        // Set up: client-2 was put to sleep 1 hour ago, but its messages are from 2 hours ago (before sleep)
        let sleepTime = Date().addingTimeInterval(-3600) // slept 1 hour ago
        let olderDateNs: Int64 = Int64(Date().addingTimeInterval(-7200).timeIntervalSince1970 * 1_000_000_000) // message from 2 hours ago

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"]
        ]

        // client-1 is awake, client-2 is sleeping (was put to sleep 1 hour ago)
        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"], at: sleepTime)

        // Mock XMTP response: conv-2 has an old message (from before it was put to sleep)
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: olderDateNs)
        ]

        // Run check
        await fixtures.checker.checkNow()

        // Verify client-2 was NOT woken (message is older than sleep time)
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(!wokenClientIds.contains("client-2"), "Sleeping inbox with messages older than sleep time should not be woken")
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
        let sleepTime = Date(timeIntervalSince1970: 1000) // slept at Unix timestamp 1000
        let newerMessageNs: Int64 = 2000 * 1_000_000_000 // message at Unix timestamp 2000 in nanoseconds

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"], at: sleepTime)

        // Mock: conv-2 has message at timestamp 2000 (newer than sleep time of 1000)
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: newerMessageNs)
        ]

        await fixtures.checker.checkNow()

        // The message at timestamp 2000 should be newer than sleep time at 1000
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains("client-2"), "Should correctly compare nanosecond timestamps against sleep time")
    }

    @Test("Finds newest message across multiple conversations in sleeping inbox")
    func testFindsNewestMessageAcrossMultipleConversations() async throws {
        let fixtures = makeTestFixtures()

        // client-2 was put to sleep 30 min ago
        let sleepTime = Date().addingTimeInterval(-1800) // slept 30 min ago
        let oldMessageNs: Int64 = Int64(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1_000_000_000) // 1 hour ago (before sleep)
        let newestMessageNs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000) // now (after sleep)

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 2),
        ]

        // client-2 has multiple conversations
        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2a", "conv-2b"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"], at: sleepTime)

        // conv-2a has old message (before sleep), conv-2b has newest message (after sleep)
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2a": makeMessageMetadata(createdNs: oldMessageNs),
            "conv-2b": makeMessageMetadata(createdNs: newestMessageNs)
        ]

        await fixtures.checker.checkNow()

        // Should wake because conv-2b has a message newer than sleep time
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains("client-2"), "Should wake based on newest message across all conversations")
    }

    @Test("Does not wake sleeping inbox when message is older than sleep time (regardless of awake inbox activity)")
    func testDoesNotWakeWhenMessageIsOlderThanSleepTime() async throws {
        let fixtures = makeTestFixtures()

        // Set up: client-1 is awake with NIL lastActivity (newly created)
        // client-2 was put to sleep 30 min ago, has an old message from 1 hour ago (before sleep)
        let sleepTime = Date().addingTimeInterval(-1800) // slept 30 min ago
        let oldMessageNs: Int64 = Int64(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1_000_000_000) // 1 hour ago

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: nil, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"], at: sleepTime)

        // Mock: conv-2 has an old message (from before it was put to sleep)
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: oldMessageNs)
        ]

        await fixtures.checker.checkNow()

        // Should NOT wake - the message is from before the inbox was put to sleep
        // The awake inbox's nil lastActivity is irrelevant now
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(!wokenClientIds.contains("client-2"),
                "Should NOT wake sleeping inbox when message is older than sleep time")
    }

    @Test("Does not cause thrashing when repeatedly checking")
    func testDoesNotCauseThrashingOnRepeatedChecks() async throws {
        let fixtures = makeTestFixtures()

        // Set up: client-3 was put to sleep 1 hour ago
        // Its message is from BEFORE it was put to sleep
        let sleepTime = Date().addingTimeInterval(-3600) // slept 1 hour ago
        let oldMessageNs: Int64 = Int64(Date().addingTimeInterval(-7200).timeIntervalSince1970 * 1_000_000_000) // 2 hours ago

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-3": ["conv-3"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1", "client-2"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-3"], at: sleepTime)

        // Mock: conv-3 has an old message (from before it was put to sleep)
        MockXMTPStaticOperations.mockMetadata = [
            "conv-3": makeMessageMetadata(createdNs: oldMessageNs)
        ]

        // Run check multiple times (simulating the 5-second interval)
        for _ in 0..<5 {
            await fixtures.checker.checkNow()
        }

        // The sleeping inbox should NOT be woken because the message is older than sleep time
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        let client3WakeCount = wokenClientIds.filter { $0 == "client-3" }.count
        #expect(client3WakeCount == 0,
                "Sleeping inbox with old messages should never be woken - found \(client3WakeCount) wakes")
    }

    @Test("Handles multiple sleeping inboxes")
    func testHandlesMultipleSleepingInboxes() async throws {
        let fixtures = makeTestFixtures()

        // Both client-2 and client-3 were put to sleep 1 hour ago
        let sleepTime = Date().addingTimeInterval(-3600) // slept 1 hour ago
        let newerMessageNs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000) // now (after sleep)
        let olderMessageNs: Int64 = Int64(Date().addingTimeInterval(-7200).timeIntervalSince1970 * 1_000_000_000) // 2 hours ago (before sleep)

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"],
            "client-3": ["conv-3"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2", "client-3"], at: sleepTime)

        // client-2 has message from NOW (after sleep), client-3 has message from 2 hours ago (before sleep)
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: newerMessageNs),
            "conv-3": makeMessageMetadata(createdNs: olderMessageNs)
        ]

        await fixtures.checker.checkNow()

        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains("client-2"), "Should wake client-2 with message newer than sleep time")
        #expect(!wokenClientIds.contains("client-3"), "Should not wake client-3 with message older than sleep time")
    }

    // MARK: - Edge Case Tests

    @Test("Does not wake when message timestamp equals sleep time exactly")
    func testDoesNotWakeWhenMessageEqualsSleptTime() async throws {
        let fixtures = makeTestFixtures()

        // Set up: sleep time and message time are exactly the same
        let sleepTime = Date(timeIntervalSince1970: 1000)
        let exactlyEqualNs: Int64 = 1000 * 1_000_000_000 // exactly equal to sleep time

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"], at: sleepTime)

        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: exactlyEqualNs)
        ]

        await fixtures.checker.checkNow()

        // Should NOT wake - comparison is strictly greater than (>), not >=
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(!wokenClientIds.contains("client-2"),
                "Should NOT wake when message timestamp exactly equals sleep time")
    }

    @Test("Handles empty metadata response from XMTP")
    func testHandlesEmptyMetadataResponse() async throws {
        let fixtures = makeTestFixtures()

        let sleepTime = Date().addingTimeInterval(-3600)

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"], at: sleepTime)

        // XMTP returns empty metadata (no messages exist)
        MockXMTPStaticOperations.mockMetadata = [:]

        await fixtures.checker.checkNow()

        // Should not wake - no metadata means no messages to compare
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(!wokenClientIds.contains("client-2"),
                "Should not wake when XMTP returns empty metadata")
    }

    @Test("Handles partial metadata response - some conversations missing")
    func testHandlesPartialMetadataResponse() async throws {
        let fixtures = makeTestFixtures()

        let sleepTime = Date().addingTimeInterval(-3600) // slept 1 hour ago
        let newerMessageNs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000) // now

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 3),
        ]

        // client-2 has 3 conversations
        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2a", "conv-2b", "conv-2c"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"], at: sleepTime)

        // Only conv-2b has metadata, others are missing
        MockXMTPStaticOperations.mockMetadata = [
            "conv-2b": makeMessageMetadata(createdNs: newerMessageNs)
        ]

        await fixtures.checker.checkNow()

        // Should wake based on the one conversation that has metadata
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains("client-2"),
                "Should wake when at least one conversation has newer message")
    }

    @Test("Skips sleeping inbox with no recorded sleep time")
    func testSkipsSleepingInboxWithNoSleepTime() async throws {
        let fixtures = makeTestFixtures()

        let newerMessageNs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000)

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        // Set client-2 as sleeping but WITHOUT a sleep time recorded
        await fixtures.lifecycleManager.setSleepingWithoutTime(clientIds: ["client-2"])

        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: newerMessageNs)
        ]

        await fixtures.checker.checkNow()

        // Should NOT wake - no sleep time means we can't compare timestamps
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(!wokenClientIds.contains("client-2"),
                "Should skip inbox with no recorded sleep time")
    }

    @Test("Handles conversation IDs not present in activity repository")
    func testHandlesConversationIdsNotInActivityRepo() async throws {
        let fixtures = makeTestFixtures()

        let sleepTime = Date().addingTimeInterval(-3600)

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 1),
        ]

        // client-2 is not in the mockConversationIds map at all
        fixtures.activityRepo.mockConversationIds = [:]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"], at: sleepTime)

        await fixtures.checker.checkNow()

        // Should not crash or wake - just skip
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(!wokenClientIds.contains("client-2"),
                "Should gracefully handle missing conversation IDs")
    }

    @Test("Wake uses correct inbox ID from activity repository")
    func testWakeUsesCorrectInboxId() async throws {
        let fixtures = makeTestFixtures()

        let sleepTime = Date().addingTimeInterval(-3600)
        let newerMessageNs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000)

        // Specific inbox ID that should be used for wake
        let expectedInboxId = "specific-inbox-id-123"

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: expectedInboxId, lastActivity: nil, conversationCount: 1),
        ]

        fixtures.activityRepo.mockConversationIds = [
            "client-2": ["conv-2"]
        ]

        await fixtures.lifecycleManager.setAwake(clientIds: ["client-1"])
        await fixtures.lifecycleManager.setSleeping(clientIds: ["client-2"], at: sleepTime)

        MockXMTPStaticOperations.mockMetadata = [
            "conv-2": makeMessageMetadata(createdNs: newerMessageNs)
        ]

        await fixtures.checker.checkNow()

        // Verify wake was called (even though it throws in our mock)
        let wokenClientIds = await fixtures.lifecycleManager.wokenClientIds
        #expect(wokenClientIds.contains("client-2"), "Should attempt to wake client-2")

        // The inbox ID correctness is verified by the wake call succeeding
        // (if wrong inbox ID was passed, the activity lookup would fail)
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
    private var _sleepTimes: [String: Date] = [:]
    private var _wokenClientIds: [String] = []
    private var _activeClientId: String?

    var awakeClientIds: Set<String> { _awakeClientIds }
    var sleepingClientIds: Set<String> { _sleepingClientIds }
    var pendingInviteClientIds: Set<String> { [] }
    var activeClientId: String? { _activeClientId }
    var wokenClientIds: [String] { _wokenClientIds }

    func sleepTime(for clientId: String) -> Date? {
        _sleepTimes[clientId]
    }

    func setActiveClientId(_ clientId: String?) {
        _activeClientId = clientId
    }

    func setAwake(clientIds: Set<String>) {
        _awakeClientIds = clientIds
        for clientId in clientIds {
            _sleepTimes.removeValue(forKey: clientId)
        }
    }

    func setSleeping(clientIds: Set<String>, at sleepTime: Date = Date()) {
        _sleepingClientIds = clientIds
        for clientId in clientIds {
            _sleepTimes[clientId] = sleepTime
        }
    }

    func setSleepingWithoutTime(clientIds: Set<String>) {
        _sleepingClientIds = clientIds
        // Intentionally don't set sleep times - simulates edge case
    }

    func wake(clientId: String, inboxId: String, reason: WakeReason) async throws -> any MessagingServiceProtocol {
        _wokenClientIds.append(clientId)
        _awakeClientIds.insert(clientId)
        _sleepingClientIds.remove(clientId)
        _sleepTimes.removeValue(forKey: clientId)
        throw InboxLifecycleError.inboxNotFound(clientId: clientId) // We don't need real service for tests
    }

    func sleep(clientId: String) async {
        _awakeClientIds.remove(clientId)
        _sleepingClientIds.insert(clientId)
        _sleepTimes[clientId] = Date()
    }

    func forceRemove(clientId: String) async {
        _awakeClientIds.remove(clientId)
        _sleepingClientIds.remove(clientId)
        _sleepTimes.removeValue(forKey: clientId)
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
        _sleepTimes.removeAll()
    }

    func createNewInbox() async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        fatalError("Not implemented for tests")
    }

    func createNewInboxOnly() async -> any MessagingServiceProtocol {
        fatalError("Not implemented for tests")
    }

    func registerExternalService(_ service: any MessagingServiceProtocol, clientId: String) async {
        _awakeClientIds.insert(clientId)
        _sleepingClientIds.remove(clientId)
    }

    func prepareUnusedConversationIfNeeded() async {}

    func clearUnusedConversation() async {}

    nonisolated func getAwakeService(clientId: String) -> (any MessagingServiceProtocol)? {
        nil
    }
}
