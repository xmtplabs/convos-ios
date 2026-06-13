@testable import ConvosConnections
import Foundation
import Testing

@Suite("InMemoryHealthBackgroundSubscriptionStore")
struct InMemoryHealthBackgroundSubscriptionStoreTests {
    private func makeSubscription(
        conversationId: String = "conv-1",
        agentInboxId: String = "agent-1",
        type: HealthSampleType = .stepCount,
        frequency: HealthBackgroundFrequency = .hourly,
        historyDays: Int = 7,
        anchor: Data? = nil
    ) -> HealthBackgroundSubscription {
        HealthBackgroundSubscription(
            conversationId: conversationId,
            agentInboxId: agentInboxId,
            typeIdentifier: type,
            frequency: frequency,
            historyDays: historyDays,
            anchor: anchor
        )
    }

    @Test("upsert inserts then replaces at the same key")
    func upsertReplaces() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore()
        try await store.upsert(makeSubscription(frequency: .hourly))
        try await store.upsert(makeSubscription(frequency: .immediate))

        let all = try await store.allSubscriptions()
        #expect(all.count == 1)
        #expect(all.first?.frequency == .immediate)
    }

    @Test("upsert distinguishes by conversationId, agentInboxId, and typeIdentifier")
    func upsertDistinctKeys() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore()
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-2", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .sleepAnalysis))
        try await store.upsert(makeSubscription(conversationId: "conv-1", agentInboxId: "agent-2", type: .stepCount))

        let all = try await store.allSubscriptions()
        #expect(all.count == 4)
    }

    @Test("delete removes only the matching row")
    func deleteRemovesOne() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore()
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .sleepAnalysis))

        try await store.delete(conversationId: "conv-1", agentInboxId: "agent-1", typeIdentifier: .stepCount)

        let all = try await store.allSubscriptions()
        #expect(all.count == 1)
        #expect(all.first?.typeIdentifier == .sleepAnalysis)
    }

    @Test("delete is a no-op when no row matches")
    func deleteNoMatch() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore()
        try await store.upsert(makeSubscription())
        try await store.delete(conversationId: "missing", agentInboxId: "agent-1", typeIdentifier: .stepCount)
        let all = try await store.allSubscriptions()
        #expect(all.count == 1)
    }

    @Test("updateAnchor advances anchor and refreshes updatedAt")
    func updateAnchorAdvances() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore()
        let subscription = makeSubscription(anchor: nil)
        try await store.upsert(subscription)

        let anchor = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await store.updateAnchor(
            conversationId: "conv-1",
            agentInboxId: "agent-1",
            typeIdentifier: .stepCount,
            anchor: anchor
        )

        let all = try await store.allSubscriptions()
        #expect(all.first?.anchor == anchor)
        #expect((all.first?.updatedAt ?? .distantPast) >= subscription.updatedAt)
    }

    @Test("updateAnchor is a no-op when no row matches")
    func updateAnchorNoMatch() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore()
        try await store.updateAnchor(
            conversationId: "missing",
            agentInboxId: "agent-1",
            typeIdentifier: .stepCount,
            anchor: Data([0x01])
        )
        let all = try await store.allSubscriptions()
        #expect(all.isEmpty)
    }

    @Test("subscriptions(forType:) filters across conversations and agents")
    func filterByType() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore()
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-2", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .sleepAnalysis))

        let steps = try await store.subscriptions(forType: .stepCount)
        #expect(steps.map(\.conversationId) == ["conv-1", "conv-2"])

        let sleep = try await store.subscriptions(forType: .sleepAnalysis)
        #expect(sleep.map(\.conversationId) == ["conv-1"])
    }

    @Test("subscriptions(forConversation:) filters by conversation")
    func filterByConversation() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore()
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .sleepAnalysis))
        try await store.upsert(makeSubscription(conversationId: "conv-2", type: .stepCount))

        let inConv1 = try await store.subscriptions(forConversation: "conv-1")
        #expect(Set(inConv1.map(\.typeIdentifier)) == [.stepCount, .sleepAnalysis])

        let inConv2 = try await store.subscriptions(forConversation: "conv-2")
        #expect(inConv2.map(\.typeIdentifier) == [.stepCount])
    }

    @Test("HealthBackgroundFrequency aggressivenessRank orders correctly")
    func frequencyRanking() {
        #expect(HealthBackgroundFrequency.immediate.aggressivenessRank > HealthBackgroundFrequency.hourly.aggressivenessRank)
        #expect(HealthBackgroundFrequency.hourly.aggressivenessRank > HealthBackgroundFrequency.daily.aggressivenessRank)
        #expect(HealthBackgroundFrequency.daily.aggressivenessRank > HealthBackgroundFrequency.weekly.aggressivenessRank)
    }
}
