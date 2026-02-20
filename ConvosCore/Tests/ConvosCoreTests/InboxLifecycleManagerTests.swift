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

    @Test("Inbox with NULL lastActivity is not evicted by LRU")
    func testNullActivityInboxNotEvicted() async throws {
        let fixtures = makeTestFixtures(maxAwake: 2)
        let manager = fixtures.manager

        let oldDate = Date().addingTimeInterval(-3600) // 1 hour ago

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 0),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: Date(), conversationCount: 1),
        ]

        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .userInteraction)

        #expect(await manager.awakeClientIds.count == 2)

        try await manager.wakeAndDiscard(clientId: "client-3", inboxId: "inbox-3", reason: .userInteraction)

        #expect(await manager.isAwake(clientId: "client-2"), "NULL activity inbox should NOT be evicted")
        #expect(await manager.isSleeping(clientId: "client-1"), "Inbox with activity should be evicted instead")
        #expect(await manager.isAwake(clientId: "client-3"))
    }

    @Test("Old inbox with NULL lastActivity CAN be evicted after protection window")
    func testOldNullActivityInboxCanBeEvicted() async throws {
        let fixtures = makeTestFixtures(maxAwake: 2)
        let manager = fixtures.manager

        let recentDate = Date()
        let oldCreatedAt = Date().addingTimeInterval(-(SleepingInboxMessageChecker.newInboxProtectionWindow + 60))

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: recentDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: nil, conversationCount: 0, createdAt: oldCreatedAt),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: Date(), conversationCount: 1),
        ]

        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .userInteraction)

        #expect(await manager.awakeClientIds.count == 2)

        try await manager.wakeAndDiscard(clientId: "client-3", inboxId: "inbox-3", reason: .userInteraction)

        #expect(await manager.isSleeping(clientId: "client-2"), "Old NULL activity inbox SHOULD be evicted after protection window")
        #expect(await manager.isAwake(clientId: "client-1"))
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

    // MARK: - App Launch Tests

    @Test("initializeOnAppLaunch sets sleep times for sleeping inboxes")
    func testInitializeOnAppLaunchSetsSleepTimes() async throws {
        let fixtures = makeTestFixtures(maxAwake: 1)
        let manager = fixtures.manager

        // Set up 3 inboxes with different activity times
        let oldDate = Date().addingTimeInterval(-3600) // 1 hour ago (least recent)
        let midDate = Date().addingTimeInterval(-1800) // 30 min ago
        let newDate = Date() // now (most recent - this one will be woken)

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: midDate, conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: newDate, conversationCount: 1),
        ]

        // Initialize on app launch - with maxAwake=1, only client-3 (most recent) should wake
        await manager.initializeOnAppLaunch()

        // Verify client-3 is awake
        #expect(await manager.isAwake(clientId: "client-3"), "Most recent inbox should be awake")

        // Verify client-1 and client-2 are sleeping
        #expect(await manager.isSleeping(clientId: "client-1"), "Older inbox should be sleeping")
        #expect(await manager.isSleeping(clientId: "client-2"), "Older inbox should be sleeping")

        // Critical: Verify sleeping inboxes have sleep times set
        // This is required for SleepingInboxMessageChecker to check them for new messages
        let sleepTime1 = await manager.sleepTime(for: "client-1")
        let sleepTime2 = await manager.sleepTime(for: "client-2")

        #expect(sleepTime1 != nil, "Sleeping inbox must have sleep time set for SleepingInboxMessageChecker")
        #expect(sleepTime2 != nil, "Sleeping inbox must have sleep time set for SleepingInboxMessageChecker")
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

// MARK: - Race Condition Tests with SleepingInboxMessageChecker

@Suite("InboxLifecycleManager Race Condition Tests", .serialized)
struct InboxLifecycleManagerRaceConditionTests {

    @Test("New inbox from unused cache is protected during creation when other inboxes wake concurrently")
    func testNewInboxProtectedDuringConcurrentWakes() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()

        // Create a mock unused inbox cache that delays during consume
        let mockUnusedCache = DelayingMockUnusedInboxCache()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 3,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedInboxCache: mockUnusedCache
        )

        // Set up existing inboxes: client-1, client-2 are awake, client-3 is sleeping
        let oldDate = Date().addingTimeInterval(-3600)
        let midDate = Date().addingTimeInterval(-1800)
        let recentDate = Date()

        activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: midDate, conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: recentDate, conversationCount: 1),
        ]

        // Wake client-1 and client-2 (2 of 3 capacity)
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .appLaunch)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .appLaunch)

        #expect(await manager.awakeClientIds.count == 2)

        // Simulate sleeping client-3
        await manager.setSleepingForTest(clientId: "client-3")

        // Now start creating a new inbox - this will be delayed by the mock cache
        let createTask = Task {
            let service = await manager.createNewInbox()
            return service.clientId
        }

        // Wait for the mock cache to signal it's in the middle of consume
        await mockUnusedCache.waitForConsumeStarted()

        // While createNewInbox is awaiting, wake client-3 (simulating SleepingInboxMessageChecker)
        // This brings us to capacity (3)
        try await manager.wakeAndDiscard(clientId: "client-3", inboxId: "inbox-3", reason: .activityRanking)

        // Now we're at capacity. Let the createNewInbox continue.
        await mockUnusedCache.resumeConsume()

        // Wait for the creation to complete
        let newClientId = await createTask.value

        // The new inbox should be awake (even though we were at capacity when it was added)
        #expect(await manager.isAwake(clientId: newClientId), "New inbox should be awake")

        // We may have 4 awake inboxes temporarily, which is OK.
        // The important thing is the NEW inbox is not evicted.
        let awakeCount = await manager.awakeClientIds.count
        #expect(awakeCount >= 3, "Should have at least 3 awake inboxes including the new one")
    }

    @Test("forceRemove updates activeClientId protection correctly")
    func testForceRemoveActiveClientIdBehavior() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()
        let mockUnusedCache = SimpleMockUnusedInboxCache()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 2,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedInboxCache: mockUnusedCache
        )

        let oldDate = Date().addingTimeInterval(-3600)
        let newDate = Date()

        activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: newDate, conversationCount: 1),
        ]

        // Wake client-1, set it as active
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .userInteraction)
        await manager.setActiveClientId("client-1")

        #expect(await manager.activeClientId == "client-1")

        // Force remove client-1 (simulating deletion)
        await manager.forceRemove(clientId: "client-1")

        // The activeClientId should be cleared when the active inbox is removed
        let activeAfterRemove = await manager.activeClientId
        #expect(activeAfterRemove == nil, "activeClientId should be cleared after forceRemove")

        // Now create a new inbox
        let service = await manager.createNewInbox()
        let newClientId = service.clientId

        // The new inbox should now be the active client
        let activeAfterCreate = await manager.activeClientId
        #expect(activeAfterCreate == newClientId, "New inbox should be the active client")

        // The new inbox should be awake
        #expect(await manager.isAwake(clientId: newClientId), "New inbox should be awake")
    }

    @Test("Deleted active inbox ID does not protect non-existent inbox during LRU eviction")
    func testDeletedActiveClientDoesNotBlockEviction() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()
        let mockUnusedCache = SimpleMockUnusedInboxCache()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 2,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedInboxCache: mockUnusedCache
        )

        let oldDate = Date().addingTimeInterval(-3600)
        let midDate = Date().addingTimeInterval(-1800)
        let newDate = Date()

        activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: oldDate, conversationCount: 1),
            InboxActivity(clientId: "client-2", inboxId: "inbox-2", lastActivity: midDate, conversationCount: 1),
            InboxActivity(clientId: "client-3", inboxId: "inbox-3", lastActivity: newDate, conversationCount: 1),
        ]

        // Wake and set client-1 as active, then delete it
        try await manager.wakeAndDiscard(clientId: "client-1", inboxId: "inbox-1", reason: .userInteraction)
        await manager.setActiveClientId("client-1")
        await manager.forceRemove(clientId: "client-1")

        // Wake client-2 and client-3 (at capacity now)
        try await manager.wakeAndDiscard(clientId: "client-2", inboxId: "inbox-2", reason: .appLaunch)
        try await manager.wakeAndDiscard(clientId: "client-3", inboxId: "inbox-3", reason: .appLaunch)

        #expect(await manager.awakeClientIds.count == 2)

        // Now create a new inbox (at capacity, should evict)
        let service = await manager.createNewInbox()
        let newClientId = service.clientId

        // The new inbox should be awake
        #expect(await manager.isAwake(clientId: newClientId), "New inbox should be awake")

        // One of the existing inboxes should be slept (client-2 is older)
        #expect(await manager.isSleeping(clientId: "client-2"), "Older inbox should be evicted")

        // client-3 should still be awake (it's the most recent)
        #expect(await manager.isAwake(clientId: "client-3"), "Recent inbox should stay awake")
    }
}

// MARK: - Inbox Creation Failure Tests

@Suite("InboxLifecycleManager Creation Failure Tests", .serialized)
struct InboxLifecycleManagerCreationFailureTests {

    /// Reproduces the bug: create inbox → delete → background creates new unused inbox → rebalance → create again
    /// The bug is: rebalance() wakes the unused inbox from DB, creating service A.
    /// Then createNewInbox() returns service B from cache with the SAME clientId.
    /// Result: Service A is orphaned (still running) and service B overwrites it.
    @Test("Rebalance should NOT wake unused inbox from database")
    func testRebalanceShouldNotWakeUnusedInbox() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()

        // Create a mock cache that tracks which inbox is unused
        let mockUnusedCache = TrackingMockUnusedInboxCache()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 3,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedInboxCache: mockUnusedCache
        )

        // Step 1: Create first inbox (consumes unused inbox "unused-1")
        let service1 = await manager.createNewInbox()
        let clientId1 = service1.clientId
        #expect(clientId1 == "unused-client-1")
        #expect(await manager.isAwake(clientId: clientId1))

        // Step 2: Delete the inbox (simulates user deleting the conversation)
        await manager.forceRemove(clientId: clientId1)
        #expect(await manager.awakeClientIds.isEmpty)

        // Step 3: Simulate background creation of new unused inbox
        // The unused inbox is now saved to DB with NULL lastActivity
        // This is the KEY: the unused inbox appears in the database
        await mockUnusedCache.setCurrentUnusedInbox(clientId: "unused-client-2", inboxId: "unused-inbox-2")
        activityRepo.activities = [
            InboxActivity(clientId: "unused-client-2", inboxId: "unused-inbox-2", lastActivity: nil, conversationCount: 0)
        ]

        // Step 4: Simulate user navigating (triggers rebalance)
        // BUG: rebalance sees unused-client-2 in DB and wakes it
        await manager.rebalance()

        // ASSERTION: The unused inbox should NOT be woken by rebalance
        // It should stay in the cache until createNewInbox() is called
        let awakeAfterRebalance = await manager.awakeClientIds
        #expect(!awakeAfterRebalance.contains("unused-client-2"),
                "BUG: Rebalance should NOT wake the unused inbox from database. It's reserved for createNewInbox().")

        // If this assertion fails, it proves the bug exists:
        // The unused inbox is being dual-tracked (in awakeInboxes AND in the cache)
    }

    @Test("Second inbox creation after delete and rebalance should succeed")
    func testSecondInboxCreationAfterDeleteAndRebalance() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()

        // Create a mock cache that tracks consumed inboxes and can "create" new ones
        let mockUnusedCache = SequentialMockUnusedInboxCache()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 3,
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedInboxCache: mockUnusedCache
        )

        // Step 1: Create first inbox (consumes unused inbox "unused-1")
        let service1 = await manager.createNewInbox()
        let clientId1 = service1.clientId
        #expect(clientId1 == "unused-client-1")
        #expect(await manager.isAwake(clientId: clientId1))

        // Step 2: Delete the inbox (simulates user deleting the conversation)
        await manager.forceRemove(clientId: clientId1)
        #expect(await manager.awakeClientIds.isEmpty)

        // Step 3: Simulate background creation of new unused inbox
        // The unused inbox is now saved to DB with NULL lastActivity
        activityRepo.activities = [
            InboxActivity(clientId: "unused-client-2", inboxId: "unused-inbox-2", lastActivity: nil, conversationCount: 0)
        ]
        await mockUnusedCache.markNewInboxAvailable()

        // Step 4: Simulate user navigating (triggers rebalance)
        // This is the key - rebalance sees the unused inbox in DB and may wake it
        await manager.rebalance()

        // Check current state - the unused inbox may now be tracked by the manager
        let awakeAfterRebalance = await manager.awakeClientIds
        let sleepingAfterRebalance = await manager.sleepingClientIds

        // Step 5: Try to create another inbox
        let service2 = await manager.createNewInbox()
        let clientId2 = service2.clientId

        // The second inbox should be successfully created and awake
        #expect(await manager.isAwake(clientId: clientId2), "Second inbox should be awake")

        // Verify we're not in a broken state with duplicate tracking
        let finalAwake = await manager.awakeClientIds
        #expect(finalAwake.contains(clientId2), "New inbox should be in awake set")

        // Log the state for debugging
        print("After rebalance: awake=\(awakeAfterRebalance), sleeping=\(sleepingAfterRebalance)")
        print("After second create: clientId2=\(clientId2), awake=\(finalAwake)")
    }

    @Test("Create inbox after delete with other awake inboxes does not cause eviction of new inbox")
    func testCreateAfterDeleteWithOtherAwakeInboxes() async throws {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()
        let mockUnusedCache = SequentialMockUnusedInboxCache()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 2, // Low capacity to trigger eviction scenarios
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: pendingInviteRepo,
            unusedInboxCache: mockUnusedCache
        )

        // Set up an existing inbox that's been active
        activityRepo.activities = [
            InboxActivity(clientId: "existing-1", inboxId: "inbox-1", lastActivity: Date().addingTimeInterval(-3600), conversationCount: 5)
        ]

        // Wake the existing inbox
        try await manager.wakeAndDiscard(clientId: "existing-1", inboxId: "inbox-1", reason: .appLaunch)
        #expect(await manager.awakeClientIds.count == 1)

        // Step 1: Create first new inbox (now at 2/2 capacity)
        let service1 = await manager.createNewInbox()
        let clientId1 = service1.clientId
        #expect(await manager.awakeClientIds.count == 2)

        // Step 2: Delete the new inbox
        await manager.forceRemove(clientId: clientId1)
        #expect(await manager.awakeClientIds.count == 1)

        // Step 3: Background creates new unused inbox (saved to DB with NULL lastActivity)
        activityRepo.activities = [
            InboxActivity(clientId: "existing-1", inboxId: "inbox-1", lastActivity: Date().addingTimeInterval(-3600), conversationCount: 5),
            InboxActivity(clientId: "unused-client-2", inboxId: "unused-inbox-2", lastActivity: nil, conversationCount: 0)
        ]
        await mockUnusedCache.markNewInboxAvailable()

        // Step 4: Rebalance (simulates user activity)
        await manager.rebalance()

        // Step 5: Create another new inbox
        let service2 = await manager.createNewInbox()
        let clientId2 = service2.clientId

        // The new inbox should be awake and functioning
        #expect(await manager.isAwake(clientId: clientId2), "New inbox should be awake after creation")
        #expect(await manager.activeClientId == clientId2, "New inbox should be active")
    }
}

// MARK: - Mock UnusedInboxCache implementations

/// A mock that tracks which inbox is currently the "unused" inbox and reports it via isUnusedInbox()
actor TrackingMockUnusedInboxCache: UnusedInboxCacheProtocol {
    private var currentUnusedClientId: String? = "unused-client-1"
    private var currentUnusedInboxId: String? = "unused-inbox-1"
    private var nextNumber: Int = 1

    func setCurrentUnusedInbox(clientId: String, inboxId: String) {
        currentUnusedClientId = clientId
        currentUnusedInboxId = inboxId
    }

    func prepareUnusedInboxIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {}

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        let clientId = currentUnusedClientId ?? "unused-client-\(nextNumber)"
        currentUnusedClientId = nil
        currentUnusedInboxId = nil
        nextNumber += 1
        let mockStateManager = MockInboxStateManager(initialState: .idle(clientId: clientId))
        return MockMessagingService(inboxStateManager: mockStateManager)
    }

    func clearUnusedInboxFromKeychain() {
        currentUnusedClientId = nil
        currentUnusedInboxId = nil
    }

    func isUnusedInbox(_ inboxId: String) -> Bool {
        return inboxId == currentUnusedInboxId
    }

    func hasUnusedInbox() -> Bool {
        return currentUnusedInboxId != nil
    }
}

/// A mock that returns sequential inbox IDs and can simulate background inbox creation
actor SequentialMockUnusedInboxCache: UnusedInboxCacheProtocol {
    private var nextInboxNumber: Int = 1
    private var currentUnusedInboxId: String?

    init() {
        currentUnusedInboxId = "unused-inbox-1"
    }

    func prepareUnusedInboxIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {}

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        let clientId = "unused-client-\(nextInboxNumber)"
        currentUnusedInboxId = nil
        nextInboxNumber += 1
        // Create mock service with specific clientId
        let mockStateManager = MockInboxStateManager(initialState: .idle(clientId: clientId))
        return MockMessagingService(inboxStateManager: mockStateManager)
    }

    func clearUnusedInboxFromKeychain() {}

    func isUnusedInbox(_ inboxId: String) -> Bool {
        return inboxId == currentUnusedInboxId
    }

    func hasUnusedInbox() -> Bool {
        return currentUnusedInboxId != nil
    }

    /// Test helper: simulate background creation of new unused inbox
    func markNewInboxAvailable() {
        currentUnusedInboxId = "unused-inbox-\(nextInboxNumber)"
    }
}

/// A mock that can delay the consume operation to simulate race conditions
actor DelayingMockUnusedInboxCache: UnusedInboxCacheProtocol {
    private var consumeStartedContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var hasConsumed: Bool = false
    private var consumeStarted: Bool = false

    func prepareUnusedInboxIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {}

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        // Signal that we've started consuming
        consumeStarted = true
        consumeStartedContinuation?.resume()
        consumeStartedContinuation = nil

        // Wait for the test to tell us to continue
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }

        hasConsumed = true
        return MockMessagingService()
    }

    func clearUnusedInboxFromKeychain() {}

    func isUnusedInbox(_ inboxId: String) -> Bool {
        false
    }

    func hasUnusedInbox() -> Bool {
        !hasConsumed
    }

    // Test helpers
    func waitForConsumeStarted() async {
        if consumeStarted { return }
        await withCheckedContinuation { continuation in
            consumeStartedContinuation = continuation
        }
    }

    func resumeConsume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

/// A simple mock that returns immediately
actor SimpleMockUnusedInboxCache: UnusedInboxCacheProtocol {
    func prepareUnusedInboxIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {}

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        MockMessagingService()
    }

    func clearUnusedInboxFromKeychain() {}

    func isUnusedInbox(_ inboxId: String) -> Bool { false }

    func hasUnusedInbox() -> Bool { false }
}

// MARK: - InboxLifecycleManager Test Helpers

extension InboxLifecycleManager {
    /// Test helper to manually mark a client as sleeping
    func setSleepingForTest(clientId: String) async {
        // This is a workaround since we can't directly access _sleepingClientIds
        // We sleep the client if it's awake
        if isAwake(clientId: clientId) {
            await sleep(clientId: clientId)
        }
    }
}

// MARK: - Stale Pending Invite Expiry Tests

@Suite("InboxLifecycleManager Stale Expiry Tests", .serialized)
struct InboxLifecycleManagerStaleExpiryTests {

    @Test("Stale pending invites are detected but not deleted on app launch")
    func testStalePendingInvitesDetectedButNotDeleted() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: eightDaysAgo).insert(db)

            try makeDBConversation(
                id: "draft-stale",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "stale-tag",
                createdAt: eightDaysAgo
            ).insert(db)
        }

        let checkRepo = PendingInviteRepository(databaseReader: dbManager.dbReader)
        let hasPendingBefore = try checkRepo.hasPendingInvites(clientId: "client-1")
        #expect(hasPendingBefore == true, "Should have pending invite before launch")

        let activityRepo = MockInboxActivityRepository()
        let managerRepo = PendingInviteRepository(databaseReader: dbManager.dbReader)
        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 10,
            databaseReader: dbManager.dbReader,
            databaseWriter: dbManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: managerRepo
        )

        await manager.initializeOnAppLaunch()

        let verifyRepo = PendingInviteRepository(databaseReader: dbManager.dbReader)
        let hasPendingAfter = try verifyRepo.hasPendingInvites(clientId: "client-1")
        #expect(hasPendingAfter == true, "Stale pending invite should still exist (deletion temporarily disabled)")
    }

    @Test("Recent pending invites are not deleted on app launch")
    func testRecentPendingInvitesNotDeleted() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: twoDaysAgo).insert(db)

            try makeDBConversation(
                id: "draft-recent",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "recent-tag",
                createdAt: twoDaysAgo
            ).insert(db)
        }

        let activityRepo = MockInboxActivityRepository()
        activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: nil, conversationCount: 0)
        ]

        let managerRepo = PendingInviteRepository(databaseReader: dbManager.dbReader)
        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 10,
            databaseReader: dbManager.dbReader,
            databaseWriter: dbManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: managerRepo
        )

        await manager.initializeOnAppLaunch()

        let verifyRepo = PendingInviteRepository(databaseReader: dbManager.dbReader)
        let hasPendingAfter = try verifyRepo.hasPendingInvites(clientId: "client-1")
        #expect(hasPendingAfter == true, "Recent pending invite should not be deleted")
    }

    @Test("stalePendingInviteClientIds correctly identifies stale vs recent invites")
    func testStalePendingInviteIdentification() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)
        let oneDayAgo = Date().addingTimeInterval(-1 * 24 * 60 * 60)

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: tenDaysAgo).insert(db)
            try DBInbox(inboxId: "inbox-2", clientId: "client-2", createdAt: oneDayAgo).insert(db)

            try makeDBConversation(
                id: "draft-stale",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "stale-tag",
                createdAt: tenDaysAgo
            ).insert(db)

            try makeDBConversation(
                id: "draft-recent",
                inboxId: "inbox-2",
                clientId: "client-2",
                inviteTag: "recent-tag",
                createdAt: oneDayAgo
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: dbManager.dbReader)
        let cutoff = Date().addingTimeInterval(-InboxLifecycleManager.stalePendingInviteInterval)
        let staleIds = try repo.stalePendingInviteClientIds(olderThan: cutoff)

        #expect(staleIds.contains("client-1"), "10-day-old invite should be stale")
        #expect(!staleIds.contains("client-2"), "1-day-old invite should not be stale")
    }

    @Test("Non-draft conversations are not affected by stale cleanup")
    func testNonDraftConversationsNotAffected() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let tenDaysAgo = Date().addingTimeInterval(-10 * 24 * 60 * 60)

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: tenDaysAgo).insert(db)

            try makeDBConversation(
                id: "convo-real",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "some-tag",
                createdAt: tenDaysAgo,
                consent: .allowed
            ).insert(db)
        }

        let activityRepo = MockInboxActivityRepository()
        activityRepo.activities = [
            InboxActivity(clientId: "client-1", inboxId: "inbox-1", lastActivity: Date(), conversationCount: 1)
        ]

        let managerRepo = PendingInviteRepository(databaseReader: dbManager.dbReader)
        let manager = InboxLifecycleManager(
            maxAwakeInboxes: 10,
            databaseReader: dbManager.dbReader,
            databaseWriter: dbManager.dbWriter,
            identityStore: MockKeychainIdentityStore(),
            environment: .tests,
            platformProviders: .mock,
            activityRepository: activityRepo,
            pendingInviteRepository: managerRepo
        )

        await manager.initializeOnAppLaunch()

        let conversationCount = try await dbManager.dbReader.read { db in
            try DBConversation.filter(DBConversation.Columns.id == "convo-real").fetchCount(db)
        }
        #expect(conversationCount == 1, "Real conversation should not be deleted by stale cleanup")
    }

    // MARK: - Test Helpers

    func makeDBConversation(
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
}

// MARK: - Pending Invite Cap and Stale Expiry Tests

@Suite("InboxLifecycleManager Pending Invite Cap Tests", .serialized)
struct InboxLifecycleManagerPendingInviteCapTests {

    @Test("Pending invite inboxes are capped during app launch")
    func testPendingInvitesAreCappedOnAppLaunch() async throws {
        let fixtures = makeTestFixtures(maxAwake: 10, maxPendingInvites: 2)
        let manager = fixtures.manager

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "pi-1", inboxId: "inbox-pi-1", lastActivity: nil, conversationCount: 0),
            InboxActivity(clientId: "pi-2", inboxId: "inbox-pi-2", lastActivity: nil, conversationCount: 0),
            InboxActivity(clientId: "pi-3", inboxId: "inbox-pi-3", lastActivity: nil, conversationCount: 0),
            InboxActivity(clientId: "pi-4", inboxId: "inbox-pi-4", lastActivity: nil, conversationCount: 0),
            InboxActivity(clientId: "regular-1", inboxId: "inbox-regular-1", lastActivity: Date(), conversationCount: 1),
        ]

        fixtures.pendingInviteRepo.pendingInvites = [
            PendingInviteInfo(clientId: "pi-1", inboxId: "inbox-pi-1", pendingConversationIds: ["draft-1"]),
            PendingInviteInfo(clientId: "pi-2", inboxId: "inbox-pi-2", pendingConversationIds: ["draft-2"]),
            PendingInviteInfo(clientId: "pi-3", inboxId: "inbox-pi-3", pendingConversationIds: ["draft-3"]),
            PendingInviteInfo(clientId: "pi-4", inboxId: "inbox-pi-4", pendingConversationIds: ["draft-4"]),
        ]

        await manager.initializeOnAppLaunch()

        var awakePendingCount = 0
        var sleepingPendingCount = 0
        for pid in ["pi-1", "pi-2", "pi-3", "pi-4"] {
            if await manager.isAwake(clientId: pid) {
                awakePendingCount += 1
            } else if await manager.isSleeping(clientId: pid) {
                sleepingPendingCount += 1
            }
        }

        #expect(awakePendingCount == 2, "Only maxAwakePendingInvites (2) should be awake")
        #expect(sleepingPendingCount == 2, "Excess pending invite inboxes should be sleeping")

        #expect(await manager.isAwake(clientId: "regular-1"), "Regular inbox should still wake")
    }

    @Test("attemptWake respects pending invite cap")
    func testAttemptWakeRespectsPendingInviteCap() async throws {
        let fixtures = makeTestFixtures(maxAwake: 5, maxPendingInvites: 1)
        let manager = fixtures.manager

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "pi-1", inboxId: "inbox-pi-1", lastActivity: nil, conversationCount: 0),
            InboxActivity(clientId: "pi-2", inboxId: "inbox-pi-2", lastActivity: nil, conversationCount: 0),
        ]

        fixtures.pendingInviteRepo.pendingInvites = [
            PendingInviteInfo(clientId: "pi-1", inboxId: "inbox-pi-1", pendingConversationIds: ["draft-1"]),
            PendingInviteInfo(clientId: "pi-2", inboxId: "inbox-pi-2", pendingConversationIds: ["draft-2"]),
        ]

        try await manager.wakeAndDiscard(clientId: "pi-1", inboxId: "inbox-pi-1", reason: .pendingInvite)
        #expect(await manager.isAwake(clientId: "pi-1"))

        // At cap, but below overall capacity — should still succeed since overall capacity allows it
        try await manager.wakeAndDiscard(clientId: "pi-2", inboxId: "inbox-pi-2", reason: .pendingInvite)
        #expect(await manager.isAwake(clientId: "pi-2"), "Under overall capacity, should still wake")
    }

    @Test("wake evicts LRU for pending invite even when over pending cap")
    func testWakeEvictsLRUForPendingInviteOverCap() async throws {
        let fixtures = makeTestFixtures(maxAwake: 2, maxPendingInvites: 1)
        let manager = fixtures.manager

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "pi-1", inboxId: "inbox-pi-1", lastActivity: nil, conversationCount: 0),
            InboxActivity(clientId: "regular-1", inboxId: "inbox-r-1", lastActivity: Date(), conversationCount: 1),
            InboxActivity(clientId: "pi-2", inboxId: "inbox-pi-2", lastActivity: nil, conversationCount: 0),
        ]

        fixtures.pendingInviteRepo.pendingInvites = [
            PendingInviteInfo(clientId: "pi-1", inboxId: "inbox-pi-1", pendingConversationIds: ["draft-1"]),
            PendingInviteInfo(clientId: "pi-2", inboxId: "inbox-pi-2", pendingConversationIds: ["draft-2"]),
        ]

        try await manager.wakeAndDiscard(clientId: "pi-1", inboxId: "inbox-pi-1", reason: .pendingInvite)
        try await manager.wakeAndDiscard(clientId: "regular-1", inboxId: "inbox-r-1", reason: .appLaunch)

        #expect(await manager.awakeClientIds.count == 2)

        // wake() evicts LRU first, so pi-2 can wake even though over pending cap
        try await manager.wakeAndDiscard(clientId: "pi-2", inboxId: "inbox-pi-2", reason: .pendingInvite)
        #expect(await manager.isAwake(clientId: "pi-2"), "User-initiated wake should succeed via LRU eviction")
        #expect(await manager.isSleeping(clientId: "regular-1"), "LRU should be evicted")
    }

    @Test("Sleep allows sleeping pending invite inbox when over cap")
    func testSleepAllowsPendingInviteOverCap() async throws {
        let fixtures = makeTestFixtures(maxAwake: 10, maxPendingInvites: 1)
        let manager = fixtures.manager

        fixtures.activityRepo.activities = [
            InboxActivity(clientId: "pi-1", inboxId: "inbox-pi-1", lastActivity: nil, conversationCount: 0),
            InboxActivity(clientId: "pi-2", inboxId: "inbox-pi-2", lastActivity: nil, conversationCount: 0),
        ]

        fixtures.pendingInviteRepo.pendingInvites = [
            PendingInviteInfo(clientId: "pi-1", inboxId: "inbox-pi-1", pendingConversationIds: ["draft-1"]),
            PendingInviteInfo(clientId: "pi-2", inboxId: "inbox-pi-2", pendingConversationIds: ["draft-2"]),
        ]

        try await manager.wakeAndDiscard(clientId: "pi-1", inboxId: "inbox-pi-1", reason: .pendingInvite)
        try await manager.wakeAndDiscard(clientId: "pi-2", inboxId: "inbox-pi-2", reason: .pendingInvite)

        #expect(await manager.awakeClientIds.count == 2)

        // With 2 awake and cap of 1, sleeping pi-2 should succeed (over cap)
        await manager.sleep(clientId: "pi-2")
        #expect(await manager.isSleeping(clientId: "pi-2"), "Over-cap pending invite should be sleepable")

        // pi-1 is under the cap, so sleeping it should be prevented
        await manager.sleep(clientId: "pi-1")
        #expect(await manager.isAwake(clientId: "pi-1"), "Under-cap pending invite should not be slept")
    }

    @Test("Pending invite inboxes with no activity record are also capped")
    func testPendingInvitesNoActivityRecordAreCapped() async throws {
        let fixtures = makeTestFixtures(maxAwake: 10, maxPendingInvites: 1)
        let manager = fixtures.manager

        // No activity records — these inboxes only appear in the pending invite list
        fixtures.activityRepo.activities = []

        fixtures.pendingInviteRepo.pendingInvites = [
            PendingInviteInfo(clientId: "pi-1", inboxId: "inbox-pi-1", pendingConversationIds: ["draft-1"]),
            PendingInviteInfo(clientId: "pi-2", inboxId: "inbox-pi-2", pendingConversationIds: ["draft-2"]),
            PendingInviteInfo(clientId: "pi-3", inboxId: "inbox-pi-3", pendingConversationIds: ["draft-3"]),
        ]

        await manager.initializeOnAppLaunch()

        var awakePendingCount = 0
        for pid in ["pi-1", "pi-2", "pi-3"] {
            if await manager.isAwake(clientId: pid) {
                awakePendingCount += 1
            }
        }

        #expect(awakePendingCount == 1, "Only 1 pending invite inbox should be awake (cap = 1)")
    }

    // MARK: - Test Helpers

    struct TestFixtures {
        let manager: InboxLifecycleManager
        let activityRepo: MockInboxActivityRepository
        let pendingInviteRepo: MockPendingInviteRepository
        let databaseManager: MockDatabaseManager
    }

    func makeTestFixtures(maxAwake: Int = 50, maxPendingInvites: Int = 3) -> TestFixtures {
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let activityRepo = MockInboxActivityRepository()
        let pendingInviteRepo = MockPendingInviteRepository()

        let manager = InboxLifecycleManager(
            maxAwakeInboxes: maxAwake,
            maxAwakePendingInvites: maxPendingInvites,
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
