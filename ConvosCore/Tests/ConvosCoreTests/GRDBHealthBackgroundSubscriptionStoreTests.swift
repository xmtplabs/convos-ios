import ConvosConnections
@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("GRDBHealthBackgroundSubscriptionStore")
struct GRDBHealthBackgroundSubscriptionStoreTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(configuration: {
            var config = Configuration()
            config.foreignKeysEnabled = true
            return config
        }())
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        try dbQueue.write { db in
            for id in ["conv-1", "conv-2"] {
                try db.execute(
                    sql: """
                        INSERT INTO conversation
                            (id, clientConversationId, inviteTag, creatorId, kind, consent, createdAt)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [id, id, "tag-\(id)", "inbox-\(id)", "group", "allowed", Date()]
                )
            }
        }
        return dbQueue
    }

    private func makeStore(_ db: DatabaseQueue) -> GRDBHealthBackgroundSubscriptionStore {
        GRDBHealthBackgroundSubscriptionStore(dbWriter: db, dbReader: db)
    }

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

    @Test("upsert round-trips a subscription")
    func upsertRoundTrip() async throws {
        let db = try makeDatabase()
        let store = makeStore(db)

        let subscription = makeSubscription(historyDays: 30)
        try await store.upsert(subscription)

        let all = try await store.allSubscriptions()
        #expect(all.count == 1)
        let row = try #require(all.first)
        #expect(row.conversationId == "conv-1")
        #expect(row.agentInboxId == "agent-1")
        #expect(row.typeIdentifier == .stepCount)
        #expect(row.frequency == .hourly)
        #expect(row.historyDays == 30)
        #expect(row.anchor == nil)
    }

    @Test("upsert replaces at the same composite key")
    func upsertReplaces() async throws {
        let db = try makeDatabase()
        let store = makeStore(db)

        try await store.upsert(makeSubscription(frequency: .hourly))
        try await store.upsert(makeSubscription(frequency: .immediate, historyDays: 14))

        let all = try await store.allSubscriptions()
        #expect(all.count == 1)
        #expect(all.first?.frequency == .immediate)
        #expect(all.first?.historyDays == 14)
    }

    @Test("subscriptions persist independently across conversations and types")
    func multipleRows() async throws {
        let db = try makeDatabase()
        let store = makeStore(db)

        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-2", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .sleepAnalysis))

        let all = try await store.allSubscriptions()
        #expect(all.count == 3)
    }

    @Test("subscriptions(forType:) returns only rows for that HKObjectType")
    func filterByType() async throws {
        let db = try makeDatabase()
        let store = makeStore(db)

        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-2", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .sleepAnalysis))

        let steps = try await store.subscriptions(forType: .stepCount)
        #expect(Set(steps.map(\.conversationId)) == ["conv-1", "conv-2"])

        let sleep = try await store.subscriptions(forType: .sleepAnalysis)
        #expect(sleep.map(\.conversationId) == ["conv-1"])
    }

    @Test("subscriptions(forConversation:) returns only rows for that conversation")
    func filterByConversation() async throws {
        let db = try makeDatabase()
        let store = makeStore(db)

        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .sleepAnalysis))
        try await store.upsert(makeSubscription(conversationId: "conv-2", type: .stepCount))

        let inConv1 = try await store.subscriptions(forConversation: "conv-1")
        #expect(Set(inConv1.map(\.typeIdentifier)) == [.stepCount, .sleepAnalysis])
    }

    @Test("delete removes only the matching row")
    func deleteRemovesOne() async throws {
        let db = try makeDatabase()
        let store = makeStore(db)

        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .sleepAnalysis))

        try await store.delete(conversationId: "conv-1", agentInboxId: "agent-1", typeIdentifier: .stepCount)

        let all = try await store.allSubscriptions()
        #expect(all.count == 1)
        #expect(all.first?.typeIdentifier == .sleepAnalysis)
    }

    @Test("updateAnchor advances the persisted anchor")
    func updateAnchor() async throws {
        let db = try makeDatabase()
        let store = makeStore(db)

        try await store.upsert(makeSubscription())
        let anchor = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await store.updateAnchor(
            conversationId: "conv-1",
            agentInboxId: "agent-1",
            typeIdentifier: .stepCount,
            anchor: anchor
        )

        let all = try await store.allSubscriptions()
        #expect(all.first?.anchor == anchor)
    }

    @Test("conversation cascade delete removes subscription rows")
    func cascadeDelete() async throws {
        let db = try makeDatabase()
        let store = makeStore(db)

        try await store.upsert(makeSubscription(conversationId: "conv-1", type: .stepCount))
        try await store.upsert(makeSubscription(conversationId: "conv-2", type: .sleepAnalysis))

        try await db.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: ["conv-1"])
        }

        let all = try await store.allSubscriptions()
        #expect(all.map(\.conversationId) == ["conv-2"])
    }
}
