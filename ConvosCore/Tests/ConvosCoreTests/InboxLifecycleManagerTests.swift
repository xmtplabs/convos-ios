@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("InboxLifecycleManager Tests", .serialized)
struct InboxLifecycleManagerTests {

    // MARK: - Basic Wake/Sleep Tests

    @Test("Wake adds inbox to awake set")
    func testWakeAddsToAwakeSet() async throws {
        let fixtures = makeTestFixtures()
        let manager = fixtures.manager

        let clientId = "client-1"
        let inboxId = "inbox-1"

        // Set up mock activity
        fixtures.activityRepo.activities = [
            InboxActivity(clientId: clientId, inboxId: inboxId, lastActivity: Date(), conversationCount: 1)
        ]

        try await manager.wakeAndDiscard(clientId: clientId, inboxId: inboxId, reason: .userInteraction)

        let awakeIds = await manager.awakeClientIds
        #expect(awakeIds.contains(clientId))
        #expect(await manager.isAwake(clientId: clientId))
        let isSleeping = await manager.isSleeping(clientId: clientId)
        #expect(!isSleeping)
    }

    @Test("Sleep moves inbox from awake to sleeping")
    func testSleepMovesToSleepingSet() async throws {
        let fixtures = makeTestFixtures()
        let manager = fixtures.manager

        let clientId = "client-1"
        let inboxId = "inbox-1"

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: clientId, inboxId: inboxId, lastActivity: Date(), conversationCount: 1)
        ]

        // Wake first
        try await manager.wakeAndDiscard(clientId: clientId, inboxId: inboxId, reason: .userInteraction)
        #expect(await manager.isAwake(clientId: clientId))

        // Then sleep
        await manager.sleep(clientId: clientId)

        let isAwake = await manager.isAwake(clientId: clientId)
        #expect(!isAwake)
        #expect(await manager.isSleeping(clientId: clientId))
    }

    @Test("Wake returns existing service if already awake")
    func testWakeReturnsExistingService() async throws {
        let fixtures = makeTestFixtures()
        let manager = fixtures.manager

        let clientId = "client-1"
        let inboxId = "inbox-1"

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: clientId, inboxId: inboxId, lastActivity: Date(), conversationCount: 1)
        ]

        // Wake twice - should return same service (verified by checking awake count stays at 1)
        try await manager.wakeAndDiscard(clientId: clientId, inboxId: inboxId, reason: .userInteraction)
        let awakeCountAfterFirst = await manager.awakeClientIds.count

        try await manager.wakeAndDiscard(clientId: clientId, inboxId: inboxId, reason: .pushNotification)
        let awakeCountAfterSecond = await manager.awakeClientIds.count

        #expect(awakeCountAfterFirst == 1)
        #expect(awakeCountAfterSecond == 1)
        #expect(await manager.isAwake(clientId: clientId))
    }

    // MARK: - Capacity Tests

    @Test("Wake sleeps LRU inbox when at capacity")
    func testWakeSleepsLRUWhenAtCapacity() async throws {
        let fixtures = makeTestFixtures(maxAwake: 2)
        let manager = fixtures.manager

        // Set up 3 inboxes with different activity times
        let oldDate = Date().addingTimeInterval(-3600) // 1 hour ago
        let midDate = Date().addingTimeInterval(-1800) // 30 min ago
        let newDate = Date() // now

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: midDate, conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: newDate, conversationCount: 1),
        ]

        // Wake first two (at capacity)
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .appLaunch)

        #expect(await manager.awakeClientIds.count == 2)
        #expect(await manager.isAwake(clientId: "client-1"))
        #expect(await manager.isAwake(clientId: "client-2"))

        // Wake third - should sleep the LRU (client-1)
        try await manager.wakeAndDiscard(clientId: "client-3", inboxId: "inbox-3", reason: .userInteraction)

        #expect(await manager.awakeClientIds.count == 2)
        #expect(await manager.isSleeping(clientId: "client-1"), "LRU client should be sleeping")
        #expect(await manager.isAwake(clientId: "client-2"))
        #expect(await manager.isAwake(clientId: "client-3"))
    }

    // MARK: - Pending Invite Tests

    @Test("Cannot sleep inbox with pending invite")
    func testCannotSleepWithPendingInvite() async throws {
        let fixtures = makeTestFixtures()
        let manager = fixtures.manager

        let clientId = "client-1"
        let inboxId = "inbox-1"

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: clientId, inboxId: inboxId, lastActivity: Date(), conversationCount: 1)
        ]

        // Mark as having pending invite
        fixtures.pendingInviteRepo.pendingInvites = [
            PendingInviteInfo(clientId: clientId, inboxId: inboxId, pendingConversationIds: ["draft-123"])
        ]

        // Wake
        try await manager.wakeAndDiscard(clientId: clientId, inboxId: inboxId, reason: .pendingInvite)
        #expect(await manager.isAwake(clientId: clientId))

        // Try to sleep - should NOT sleep due to pending invite
        await manager.sleep(clientId: clientId)

        #expect(await manager.isAwake(clientId: clientId), "Should remain awake due to pending invite")
        let isSleeping = await manager.isSleeping(clientId: clientId)
        #expect(!isSleeping)
    }

    @Test("Pending invite inbox not evicted during LRU sleep")
    func testPendingInviteNotEvictedByLRU() async throws {
        let fixtures = makeTestFixtures(maxAwake: 2)
        let manager = fixtures.manager

        let oldDate = Date().addingTimeInterval(-3600) // 1 hour ago - oldest
        let newDate = Date()

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: newDate, conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: newDate, conversationCount: 1),
        ]

        // Mark client-1 (LRU) as having pending invite
        fixtures.pendingInviteRepo.pendingInvites = [
            PendingInviteInfo(clientId: "client-1", inboxId: "inbox-1", pendingConversationIds: ["draft-123"])
        ]

        // Wake first two
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .pendingInvite)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .appLaunch)

        // Wake third with eviction - client-1 has pending invite so client-2 should be evicted instead
        try await manager.wakeAndDiscard(clientId: "client-3", inboxId: "inbox-3", reason: .userInteraction)

        #expect(await manager.isAwake(clientId: "client-1"), "Pending invite inbox should not be evicted")
        #expect(await manager.isSleeping(clientId: "client-2"), "Non-pending inbox should be evicted")
        #expect(await manager.isAwake(clientId: "client-3"))
    }

    // MARK: - Rebalance Tests

    @Test("Rebalance sleeps excess inboxes")
    func testRebalanceSleepsExcessInboxes() async throws {
        let fixtures = makeTestFixtures(maxAwake: 2)
        let manager = fixtures.manager

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date().addingTimeInterval(-3600), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: Date().addingTimeInterval(-1800), conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: Date(), conversationCount: 1),
        ]

        // Manually wake 2 (at capacity)
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .appLaunch)

        // Rebalance (no active client)
        await manager.setActiveClientId(nil)
        await manager.rebalance()

        // Should maintain max 2 awake
        let awakeCount = await manager.awakeClientIds.count
        #expect(awakeCount <= 2)
    }

    // MARK: - getOrWake Tests

    @Test("getOrWake returns existing awake service")
    func testGetOrWakeReturnsExisting() async throws {
        let fixtures = makeTestFixtures()
        let manager = fixtures.manager

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1)
        ]

        // Wake first
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        let awakeCountAfterWake = await manager.awakeClientIds.count

        // getOrWake should return same service (count should stay at 1)
        try await manager.getOrWakeAndDiscard(clientId: "client-1", inboxId: "inbox-1")
        let awakeCountAfterGetOrWake = await manager.awakeClientIds.count

        #expect(awakeCountAfterWake == 1)
        #expect(awakeCountAfterGetOrWake == 1)
    }

    @Test("getOrWake wakes sleeping inbox")
    func testGetOrWakeWakesSleeping() async throws {
        let fixtures = makeTestFixtures()
        let manager = fixtures.manager

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1)
        ]

        // Wake then sleep
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        await manager.sleep(clientId: "client-1")
        #expect(await manager.isSleeping(clientId: "client-1"))

        // getOrWake should wake it
        try await manager.getOrWakeAndDiscard(clientId: "client-1", inboxId: "inbox-1")

        #expect(await manager.isAwake(clientId: "client-1"))
    }

    // MARK: - Active Conversation Change Tests

    @Test("Rebalance sleeps inboxes not in top N when active conversation changes")
    func testRebalanceSleepsNonTopNInboxes() async throws {
        let fixtures = makeTestFixtures(maxAwake: 2)
        let manager = fixtures.manager

        // Set up 3 inboxes with different activity times
        let oldDate = Date().addingTimeInterval(-3600) // 1 hour ago - oldest
        let midDate = Date().addingTimeInterval(-1800) // 30 min ago
        let newDate = Date() // now - most recent

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: midDate, conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: newDate, conversationCount: 1),
        ]

        // Wake all 3 inboxes (simulating they were all active at some point)
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .appLaunch)
        // client-3 wakes with eviction and client-1 gets evicted due to LRU
        try await manager.wakeAndDiscard(clientId: "client-3", inboxId: "inbox-3", reason: .userInteraction)

        // Verify client-1 was already slept due to capacity
        #expect(await manager.isSleeping(clientId: "client-1"), "LRU client-1 should be sleeping after capacity exceeded")

        // Now simulate user switching to client-3's conversation
        // Set client-3 as active and rebalance - client-2 should potentially be slept if over capacity
        await manager.setActiveClientId("client-3")
        await manager.rebalance()

        // client-3 should stay awake (it's the active one)
        #expect(await manager.isAwake(clientId: "client-3"), "Active client should stay awake")

        // We should have at most maxAwake (2) inboxes awake
        let awakeCount = await manager.awakeClientIds.count
        #expect(awakeCount <= 2)
    }

    @Test("Rebalance never sleeps the active client even if it has old lastActivity")
    func testRebalanceProtectsActiveClient() async throws {
        let fixtures = makeTestFixtures(maxAwake: 2)
        let manager = fixtures.manager

        // client-1 has OLDEST activity but will be the active conversation
        let veryOldDate = Date().addingTimeInterval(-7200) // 2 hours ago
        let recentDate = Date()

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: veryOldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: recentDate, conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: recentDate, conversationCount: 1),
        ]

        // Wake client-1 and client-2
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .userInteraction)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .appLaunch)

        #expect(await manager.awakeClientIds.count == 2)

        // Now wake client-3 with eviction - this should evict client-1 (oldest activity) normally
        try await manager.wakeAndDiscard(clientId: "client-3", inboxId: "inbox-3", reason: .appLaunch)

        // But if we rebalance with client-1 as active, it should be protected
        // First, let's wake client-1 again with eviction
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .userInteraction)

        // Now set client-1 (oldest activity) as the active client and rebalance
        await manager.setActiveClientId("client-1")
        await manager.rebalance()

        // client-1 should NOT be slept despite having the oldest lastActivity
        #expect(await manager.isAwake(clientId: "client-1"), "Active client should never be slept regardless of lastActivity")
    }

    @Test("Rebalance sleeps old inactive inboxes when switching conversations")
    func testRebalanceSleepsOldInboxWhenSwitchingConversations() async throws {
        let fixtures = makeTestFixtures(maxAwake: 2)
        let manager = fixtures.manager

        let oldDate = Date().addingTimeInterval(-3600)
        let newDate = Date()

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-old", inboxId: "inbox-old", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-new", inboxId: "inbox-new", lastActivity: newDate, conversationCount: 1),
            InboxActivity(clientId: "client-other", inboxId: "inbox-other", lastActivity: newDate, conversationCount: 1),
        ]

        // User is viewing client-old's conversation (wake it)
        try await manager.wakeAndDiscard(clientId: "client-old", inboxId: "inbox-old", reason: .userInteraction)
        try await manager.wakeAndDiscard(clientId: "client-new", inboxId: "inbox-new", reason: .appLaunch)

        #expect(await manager.isAwake(clientId: "client-old"))
        #expect(await manager.isAwake(clientId: "client-new"))

        // Now user switches to client-new's conversation
        // Wake client-other with eviction to trigger capacity issue
        try await manager.wakeAndDiscard(clientId: "client-other", inboxId: "inbox-other", reason: .appLaunch)

        // Set client-new as active (user switched away from client-old) and rebalance
        await manager.setActiveClientId("client-new")
        await manager.rebalance()

        // client-old should be slept (it's the LRU and no longer active)
        #expect(await manager.isSleeping(clientId: "client-old"), "Old inactive inbox should be slept")
        // client-new should stay awake (it's the active one)
        #expect(await manager.isAwake(clientId: "client-new"), "Active inbox should stay awake")
    }

    @Test("Rebalance with no active client sleeps LRU inboxes")
    func testRebalanceWithNoActiveClient() async throws {
        let fixtures = makeTestFixtures(maxAwake: 2)
        let manager = fixtures.manager

        let oldDate = Date().addingTimeInterval(-3600)
        let midDate = Date().addingTimeInterval(-1800)
        let newDate = Date()

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: midDate, conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: newDate, conversationCount: 1),
        ]

        // Wake all three (third one uses eviction)
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .appLaunch)
        try await manager.wakeAndDiscard(clientId: "client-3", inboxId: "inbox-3", reason: .appLaunch)

        // No active client (user navigated to conversation list) - rebalance
        await manager.setActiveClientId(nil)
        await manager.rebalance()

        // Should have at most 2 awake
        let awakeCount = await manager.awakeClientIds.count
        #expect(awakeCount <= 2)

        // The oldest (client-1) should be slept
        #expect(await manager.isSleeping(clientId: "client-1"), "LRU inbox should be slept when no active client")
    }

    @Test("Active inbox is not evicted by LRU when waking new inbox")
    func testActiveInboxNotEvictedByLRU() async throws {
        let fixtures = makeTestFixtures(maxAwake: 2)
        let manager = fixtures.manager

        // Set up 3 inboxes - client-1 has OLDEST activity but will be active
        let veryOldDate = Date().addingTimeInterval(-7200) // 2 hours ago
        let midDate = Date().addingTimeInterval(-1800) // 30 min ago
        let newDate = Date() // now

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: veryOldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: midDate, conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: newDate, conversationCount: 1),
        ]

        // Wake client-1 and client-2 (at capacity)
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .userInteraction)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .appLaunch)

        #expect(await manager.awakeClientIds.count == 2)

        // Set client-1 (oldest activity) as the ACTIVE inbox (user is viewing this conversation)
        await manager.setActiveClientId("client-1")

        // Now wake client-3 which triggers LRU eviction
        // Without the fix, client-1 would be evicted because it has the oldest lastActivity
        // With the fix, client-2 should be evicted instead since client-1 is active
        try await manager.wakeAndDiscard(clientId: "client-3", inboxId: "inbox-3", reason: .pushNotification)

        #expect(await manager.isAwake(clientId: "client-1"), "Active inbox should NOT be evicted despite having oldest activity")
        #expect(await manager.isSleeping(clientId: "client-2"), "Non-active inbox should be evicted instead")
        #expect(await manager.isAwake(clientId: "client-3"), "Newly woken inbox should be awake")
        #expect(await manager.awakeClientIds.count == 2)
    }

    @Test("Rebalance wakes more recent inbox when navigating back to list")
    func testRebalanceWakesMoreRecentInboxWhenNavigatingBack() async throws {
        // Scenario:
        // 1. Max awake = 1
        // 2. Inbox 1 has more recent activity than inbox 2
        // 3. User taps into inbox 2 (inbox 2 wakes, inbox 1 sleeps due to capacity)
        // 4. User taps out (rebalance with nil active)
        // 5. Inbox 1 should wake back up (more recent activity), inbox 2 should sleep

        let fixtures = makeTestFixtures(maxAwake: 1)
        let manager = fixtures.manager

        let recentDate = Date()
        let olderDate = Date().addingTimeInterval(-3600)

        // Inbox 1 has more recent activity than inbox 2
        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: recentDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: olderDate, conversationCount: 1),
        ]

        // Initially wake inbox 1 (the most recent by activity)
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        #expect(await manager.isAwake(clientId: "client-1"))
        #expect(await manager.awakeClientIds.count == 1)

        // User taps into inbox 2's conversation - wake inbox 2 with eviction (since at capacity)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .userInteraction)

        // Set inbox 2 as active and rebalance - inbox 1 should be slept (over capacity)
        await manager.setActiveClientId("client-2")
        await manager.rebalance()

        // Inbox 2 should be awake (protected as active), inbox 1 should be sleeping
        #expect(await manager.isAwake(clientId: "client-2"), "Active inbox should be awake")
        #expect(await manager.isSleeping(clientId: "client-1"), "Non-active inbox should be slept when over capacity")

        // User taps out - back to conversation list (no active conversation)
        await manager.setActiveClientId(nil)
        await manager.rebalance()

        // Now inbox 1 should be awake (more recent activity), inbox 2 should be sleeping
        #expect(await manager.isAwake(clientId: "client-1"), "More recently active inbox should wake when user navigates back")
        #expect(await manager.isSleeping(clientId: "client-2"), "Less recently active inbox should sleep when no longer active")
        #expect(await manager.awakeClientIds.count == 1, "Should only have 1 awake inbox (maxAwake = 1)")
    }

    // MARK: - Stop All Tests

    @Test("stopAll clears all state")
    func testStopAllClearsState() async throws {
        let fixtures = makeTestFixtures()
        let manager = fixtures.manager

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: Date(), conversationCount: 1),
        ]

        // Wake some inboxes
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .appLaunch)

        // Stop all
        await manager.stopAll()

        #expect(await manager.awakeClientIds.isEmpty)
        #expect(await manager.sleepingClientIds.isEmpty)
    }

    // MARK: - Test Helpers

    struct TestFixtures {
        let manager: InboxLifecycleManager
        let activityRepo: MockInboxActivityRepository
        let pendingInviteRepo: MockPendingInviteRepository
        let databaseManager: MockDatabaseManager
    }

    func makeTestFixtures(maxAwake: Int = 50) -> TestFixtures {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: maxAwake,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo
        )

        return TestFixtures(
            manager: manager,
            activityRepo: activityRepo,
            pendingInviteRepo: pendingInviteRepo,
            databaseManager: databaseManager
        )
    }
}

// MARK: - Test Helper Extensions

extension InboxLifecycleManager {
    /// Helper for tests to wake without returning the non-Sendable service
    func wakeAndDiscard(clientId: String, inboxId: String, reason: WakeReason) async throws {
        _ = try await wake(clientId: clientId, inboxId: inboxId, reason: reason)
    }

    /// Helper for tests to getOrWake without returning the non-Sendable service
    func getOrWakeAndDiscard(clientId: String, inboxId: String) async throws {
        _ = try await getOrWake(clientId: clientId, inboxId: inboxId)
    }
}
