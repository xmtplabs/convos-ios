@testable import ConvosConnections
import Foundation
import Testing

@Suite("HealthBackgroundSubscriptionManager")
struct HealthBackgroundSubscriptionManagerTests {
    private final class RecordingGateway: HealthBackgroundDeliveryGateway, @unchecked Sendable {
        struct EnableCall: Equatable {
            let typeIdentifier: HealthSampleType
            let frequency: HealthBackgroundFrequency
        }

        struct DisableCall: Equatable {
            let typeIdentifier: HealthSampleType
        }

        var enableCalls: [EnableCall] = []
        var disableCalls: [DisableCall] = []
        var enableError: Error?
        var disableError: Error?

        func setBackgroundDelivery(typeIdentifier: HealthSampleType, frequency: HealthBackgroundFrequency) async throws {
            if let enableError { throw enableError }
            enableCalls.append(EnableCall(typeIdentifier: typeIdentifier, frequency: frequency))
        }

        func disableBackgroundDelivery(typeIdentifier: HealthSampleType) async throws {
            if let disableError { throw disableError }
            disableCalls.append(DisableCall(typeIdentifier: typeIdentifier))
        }
    }

    private final class RecordingReader: HealthBackfillReader, @unchecked Sendable {
        struct Call: Equatable {
            let typeIdentifier: HealthSampleType
            let startDate: Date
            let endDate: Date
        }

        var calls: [Call] = []
        var samplesToReturn: [HealthSample] = []
        var anchorToReturn: Data?
        var errorToThrow: Error?

        func backfill(typeIdentifier: HealthSampleType, startDate: Date, endDate: Date) async throws -> HealthBackfillResult {
            calls.append(Call(typeIdentifier: typeIdentifier, startDate: startDate, endDate: endDate))
            if let errorToThrow { throw errorToThrow }
            return HealthBackfillResult(samples: samplesToReturn, anchor: anchorToReturn)
        }
    }

    private final class RecordingDelivery: ConnectionDelivering, @unchecked Sendable {
        struct PayloadDelivery: Equatable {
            let payload: ConnectionPayload
            let conversationId: String
        }

        var payloadCalls: [PayloadDelivery] = []
        var payloadError: Error?

        func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws {
            if let payloadError { throw payloadError }
            payloadCalls.append(PayloadDelivery(payload: payload, conversationId: conversationId))
        }

        func deliver(_ result: ConnectionInvocationResult, to conversationId: String) async throws {}
    }

    private struct StubError: Error {}

    private struct Harness {
        let manager: HealthBackgroundSubscriptionManager
        let store: InMemoryHealthBackgroundSubscriptionStore
        let gateway: RecordingGateway
        let reader: RecordingReader?
        let delivery: RecordingDelivery?
    }

    private func makeManager(
        store: InMemoryHealthBackgroundSubscriptionStore = InMemoryHealthBackgroundSubscriptionStore(),
        gateway: RecordingGateway = RecordingGateway(),
        reader: RecordingReader? = nil,
        delivery: RecordingDelivery? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> Harness {
        Harness(
            manager: HealthBackgroundSubscriptionManager(
                store: store,
                gateway: gateway,
                reader: reader,
                delivery: delivery,
                now: now
            ),
            store: store,
            gateway: gateway,
            reader: reader,
            delivery: delivery
        )
    }

    private func makeSubscribeInvocation(
        typeIdentifier: String = "step_count",
        frequency: String = "hourly",
        historyDays: Int? = nil,
        invocationId: String = "invoc-1"
    ) -> ConnectionInvocation {
        var args: [String: ArgumentValue] = [
            "typeIdentifier": .enumValue(typeIdentifier),
            "frequency": .enumValue(frequency),
        ]
        if let historyDays {
            args["historyDays"] = .int(historyDays)
        }
        return ConnectionInvocation(
            invocationId: invocationId,
            kind: .health,
            action: ConnectionAction(name: "subscribe_background_delivery", arguments: args)
        )
    }

    private func makeUnsubscribeInvocation(typeIdentifier: String = "step_count") -> ConnectionInvocation {
        ConnectionInvocation(
            invocationId: "invoc-unsub",
            kind: .health,
            action: ConnectionAction(
                name: "unsubscribe_background_delivery",
                arguments: ["typeIdentifier": .enumValue(typeIdentifier)]
            )
        )
    }

    // MARK: - subscribe

    @Test("subscribe persists a row, calls the gateway with the requested frequency, and replies with success")
    func subscribeHappyPath() async throws {
        let harness = makeManager()
        let manager = harness.manager
        let store = harness.store
        let gateway = harness.gateway
        let invocation = makeSubscribeInvocation()

        let result = await manager.handleSubscribe(invocation: invocation, conversationId: "conv-1", agentInboxId: "agent-1")

        #expect(result.status == .success)
        #expect(result.result["subscriptionId"]?.stringValue == "conv-1.agent-1.step_count")
        #expect(result.result["backfillSampleCount"]?.intValue == 0)

        let rows = try await store.allSubscriptions()
        #expect(rows.count == 1)
        #expect(rows.first?.frequency == .hourly)

        #expect(gateway.enableCalls == [
            RecordingGateway.EnableCall(typeIdentifier: .stepCount, frequency: .hourly),
        ])
        #expect(gateway.disableCalls.isEmpty)
    }

    @Test("subscribe defaults historyDays to the schema default when omitted")
    func subscribeDefaultsHistory() async throws {
        let harness = makeManager()
        let manager = harness.manager
        let store = harness.store
        let invocation = makeSubscribeInvocation(historyDays: nil)

        _ = await manager.handleSubscribe(invocation: invocation, conversationId: "conv-1", agentInboxId: "agent-1")

        let rows = try await store.allSubscriptions()
        #expect(rows.first?.historyDays == HealthActionSchemas.defaultHistoryDays)
    }

    @Test("subscribe clamps historyDays into the [1, maxHistoryDays] range")
    func subscribeClampsHistory() async throws {
        let harness = makeManager()
        let manager = harness.manager
        let store = harness.store

        _ = await manager.handleSubscribe(
            invocation: makeSubscribeInvocation(typeIdentifier: "step_count", historyDays: 9_999),
            conversationId: "conv-A",
            agentInboxId: "agent-1"
        )
        _ = await manager.handleSubscribe(
            invocation: makeSubscribeInvocation(typeIdentifier: "sleep_analysis", historyDays: 0),
            conversationId: "conv-A",
            agentInboxId: "agent-1"
        )

        let rows = try await store.allSubscriptions()
        let byType = Dictionary(uniqueKeysWithValues: rows.map { ($0.typeIdentifier, $0.historyDays) })
        #expect(byType[.stepCount] == HealthActionSchemas.maxHistoryDays)
        #expect(byType[.sleepAnalysis] == 1)
    }

    @Test("subscribe rejects an unsupported typeIdentifier with executionFailed")
    func subscribeUnknownType() async throws {
        let harness = makeManager()
        let manager = harness.manager
        let store = harness.store
        let gateway = harness.gateway
        let invocation = makeSubscribeInvocation(typeIdentifier: "blood_pressure")

        let result = await manager.handleSubscribe(invocation: invocation, conversationId: "conv-1", agentInboxId: "agent-1")

        #expect(result.status == .executionFailed)
        let rows = try await store.allSubscriptions()
        #expect(rows.isEmpty)
        #expect(gateway.enableCalls.isEmpty)
    }

    @Test("subscribe rejects an unsupported frequency with executionFailed")
    func subscribeUnknownFrequency() async throws {
        let harness = makeManager()
        let manager = harness.manager
        let store = harness.store
        let gateway = harness.gateway
        let invocation = makeSubscribeInvocation(frequency: "monthly")

        let result = await manager.handleSubscribe(invocation: invocation, conversationId: "conv-1", agentInboxId: "agent-1")

        #expect(result.status == .executionFailed)
        let rows = try await store.allSubscriptions()
        #expect(rows.isEmpty)
        #expect(gateway.enableCalls.isEmpty)
    }

    @Test("subscribe surfaces gateway errors as executionFailed but keeps the row")
    func subscribeGatewayFailureKeepsRow() async throws {
        let gateway = RecordingGateway()
        gateway.enableError = StubError()
        let harness = makeManager(gateway: gateway)
        let manager = harness.manager
        let store = harness.store

        let result = await manager.handleSubscribe(
            invocation: makeSubscribeInvocation(),
            conversationId: "conv-1",
            agentInboxId: "agent-1"
        )

        #expect(result.status == .executionFailed)
        let rows = try await store.allSubscriptions()
        #expect(rows.count == 1)
    }

    // MARK: - aggregation

    @Test("multiple subscribers on the same type apply the most aggressive frequency")
    func multipleSubscribersAggregate() async throws {
        let harness = makeManager()
        let manager = harness.manager
        let gateway = harness.gateway

        _ = await manager.handleSubscribe(
            invocation: makeSubscribeInvocation(frequency: "weekly", invocationId: "i-1"),
            conversationId: "conv-A",
            agentInboxId: "agent-1"
        )
        _ = await manager.handleSubscribe(
            invocation: makeSubscribeInvocation(frequency: "hourly", invocationId: "i-2"),
            conversationId: "conv-B",
            agentInboxId: "agent-2"
        )
        _ = await manager.handleSubscribe(
            invocation: makeSubscribeInvocation(frequency: "daily", invocationId: "i-3"),
            conversationId: "conv-C",
            agentInboxId: "agent-3"
        )

        // The most aggressive is `hourly`. iOS should be told that after each subscribe.
        #expect(gateway.enableCalls.map(\.frequency) == [.weekly, .hourly, .hourly])
    }

    @Test("upsert at the same composite key updates frequency without growing the row count")
    func resubscribeReplaces() async throws {
        let harness = makeManager()
        let manager = harness.manager
        let store = harness.store
        let gateway = harness.gateway

        _ = await manager.handleSubscribe(
            invocation: makeSubscribeInvocation(frequency: "weekly", invocationId: "i-1"),
            conversationId: "conv-A",
            agentInboxId: "agent-1"
        )
        _ = await manager.handleSubscribe(
            invocation: makeSubscribeInvocation(frequency: "hourly", invocationId: "i-2"),
            conversationId: "conv-A",
            agentInboxId: "agent-1"
        )

        let rows = try await store.allSubscriptions()
        #expect(rows.count == 1)
        #expect(rows.first?.frequency == .hourly)
        #expect(gateway.enableCalls.map(\.frequency) == [.weekly, .hourly])
    }

    // MARK: - unsubscribe

    @Test("unsubscribe deletes the row and disables iOS background delivery when no rows remain")
    func unsubscribeLastRowDisables() async throws {
        let harness = makeManager()
        let manager = harness.manager
        let store = harness.store
        let gateway = harness.gateway
        _ = await manager.handleSubscribe(
            invocation: makeSubscribeInvocation(),
            conversationId: "conv-A",
            agentInboxId: "agent-1"
        )

        let result = await manager.handleUnsubscribe(
            invocation: makeUnsubscribeInvocation(),
            conversationId: "conv-A",
            agentInboxId: "agent-1"
        )

        #expect(result.status == .success)
        let rows = try await store.allSubscriptions()
        #expect(rows.isEmpty)
        #expect(gateway.disableCalls.map(\.typeIdentifier) == [.stepCount])
    }

    @Test("unsubscribe leaves iOS background delivery enabled when other subscribers remain, at the new max frequency")
    func unsubscribeKeepsRemaining() async throws {
        let harness = makeManager()
        let manager = harness.manager
        let store = harness.store
        let gateway = harness.gateway
        _ = await manager.handleSubscribe(
            invocation: makeSubscribeInvocation(frequency: "hourly", invocationId: "i-1"),
            conversationId: "conv-A",
            agentInboxId: "agent-1"
        )
        _ = await manager.handleSubscribe(
            invocation: makeSubscribeInvocation(frequency: "weekly", invocationId: "i-2"),
            conversationId: "conv-B",
            agentInboxId: "agent-2"
        )

        let result = await manager.handleUnsubscribe(
            invocation: makeUnsubscribeInvocation(),
            conversationId: "conv-A",
            agentInboxId: "agent-1"
        )

        #expect(result.status == .success)
        let rows = try await store.allSubscriptions()
        #expect(rows.count == 1)
        #expect(gateway.disableCalls.isEmpty)
        #expect(gateway.enableCalls.last?.frequency == .weekly)
    }

    @Test("unsubscribe with no matching row still calls disable on the gateway and replies success")
    func unsubscribeNoMatch() async throws {
        let harness = makeManager()
        let manager = harness.manager
        let gateway = harness.gateway

        let result = await manager.handleUnsubscribe(
            invocation: makeUnsubscribeInvocation(),
            conversationId: "conv-X",
            agentInboxId: "agent-X"
        )

        #expect(result.status == .success)
        #expect(gateway.disableCalls.map(\.typeIdentifier) == [.stepCount])
    }

    @Test("unsubscribe rejects an unsupported typeIdentifier with executionFailed")
    func unsubscribeUnknownType() async throws {
        let harness = makeManager()
        let manager = harness.manager
        let invocation = ConnectionInvocation(
            invocationId: "invoc-bad",
            kind: .health,
            action: ConnectionAction(
                name: "unsubscribe_background_delivery",
                arguments: ["typeIdentifier": .enumValue("blood_pressure")]
            )
        )

        let result = await manager.handleUnsubscribe(invocation: invocation, conversationId: "conv-A", agentInboxId: "agent-1")
        #expect(result.status == .executionFailed)
    }

    // MARK: - effectiveFrequency helper

    @Test("effectiveFrequency returns nil for an empty list and the max otherwise")
    func effectiveFrequencyHelper() async {
        let manager = HealthBackgroundSubscriptionManager(
            store: InMemoryHealthBackgroundSubscriptionStore(),
            gateway: RecordingGateway()
        )
        #expect(manager.effectiveFrequency(among: []) == nil)

        let now = Date()
        let rows: [HealthBackgroundSubscription] = [
            HealthBackgroundSubscription(conversationId: "c1", agentInboxId: "a1", typeIdentifier: .stepCount, frequency: .weekly, historyDays: 7, createdAt: now, updatedAt: now),
            HealthBackgroundSubscription(conversationId: "c2", agentInboxId: "a2", typeIdentifier: .stepCount, frequency: .daily, historyDays: 7, createdAt: now, updatedAt: now),
            HealthBackgroundSubscription(conversationId: "c3", agentInboxId: "a3", typeIdentifier: .stepCount, frequency: .hourly, historyDays: 7, createdAt: now, updatedAt: now),
        ]
        #expect(manager.effectiveFrequency(among: rows) == .hourly)
    }

    // MARK: - backfill

    private static let fixedNow: Date = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeBackfillSample(
        type: HealthSampleType = .stepCount,
        offset: TimeInterval = -3600,
        value: Double = 1_234
    ) -> HealthSample {
        HealthSample(
            type: type,
            startDate: Self.fixedNow.addingTimeInterval(offset),
            endDate: Self.fixedNow.addingTimeInterval(offset),
            value: value,
            unit: "count"
        )
    }

    @Test("subscribe runs backfill across the requested window and delivers a payload before applying the gateway")
    func subscribeRunsBackfill() async throws {
        let reader = RecordingReader()
        reader.samplesToReturn = [makeBackfillSample(value: 500), makeBackfillSample(offset: -7200, value: 1_500)]
        reader.anchorToReturn = Data([0x01, 0x02])
        let delivery = RecordingDelivery()
        let harness = makeManager(reader: reader, delivery: delivery, now: { Self.fixedNow })

        let result = await harness.manager.handleSubscribe(
            invocation: makeSubscribeInvocation(historyDays: 7),
            conversationId: "conv-1",
            agentInboxId: "agent-1"
        )

        #expect(result.status == .success)
        #expect(result.result["backfillSampleCount"]?.intValue == 2)

        let expectedStart = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -7, to: Self.fixedNow) ?? Self.fixedNow
        #expect(reader.calls == [
            RecordingReader.Call(typeIdentifier: .stepCount, startDate: expectedStart, endDate: Self.fixedNow),
        ])
        #expect(delivery.payloadCalls.count == 1)
        let delivered = try #require(delivery.payloadCalls.first)
        #expect(delivered.conversationId == "conv-1")
        guard case .health(let payload) = delivered.payload.body else {
            Issue.record("delivered body should be .health")
            return
        }
        #expect(payload.samples.count == 2)
        #expect(payload.rangeStart == expectedStart)
        #expect(payload.rangeEnd == Self.fixedNow)

        let rows = try await harness.store.allSubscriptions()
        #expect(rows.first?.anchor == Data([0x01, 0x02]))
    }

    @Test("subscribe defaults backfill window to schema default when historyDays is not provided")
    func subscribeDefaultBackfillWindow() async throws {
        let reader = RecordingReader()
        let delivery = RecordingDelivery()
        let harness = makeManager(reader: reader, delivery: delivery, now: { Self.fixedNow })

        _ = await harness.manager.handleSubscribe(
            invocation: makeSubscribeInvocation(historyDays: nil),
            conversationId: "conv-1",
            agentInboxId: "agent-1"
        )

        let expectedStart = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -HealthActionSchemas.defaultHistoryDays, to: Self.fixedNow) ?? Self.fixedNow
        #expect(reader.calls.first?.startDate == expectedStart)
    }

    @Test("subscribe with no reader still succeeds and reports backfillSampleCount: 0")
    func subscribeNoReader() async throws {
        let harness = makeManager()

        let result = await harness.manager.handleSubscribe(
            invocation: makeSubscribeInvocation(),
            conversationId: "conv-1",
            agentInboxId: "agent-1"
        )

        #expect(result.status == .success)
        #expect(result.result["backfillSampleCount"]?.intValue == 0)
    }

    @Test("subscribe surfaces reader errors as executionFailed and skips the gateway call")
    func subscribeReaderFailureSurfaces() async throws {
        let reader = RecordingReader()
        reader.errorToThrow = StubError()
        let delivery = RecordingDelivery()
        let harness = makeManager(reader: reader, delivery: delivery)

        let result = await harness.manager.handleSubscribe(
            invocation: makeSubscribeInvocation(),
            conversationId: "conv-1",
            agentInboxId: "agent-1"
        )

        #expect(result.status == .executionFailed)
        let rows = try await harness.store.allSubscriptions()
        #expect(rows.count == 1)
        #expect(harness.gateway.enableCalls.isEmpty)
    }

    @Test("subscribe surfaces delivery errors as executionFailed and skips the gateway call")
    func subscribeDeliveryFailureSurfaces() async throws {
        let reader = RecordingReader()
        reader.samplesToReturn = [makeBackfillSample()]
        let delivery = RecordingDelivery()
        delivery.payloadError = StubError()
        let harness = makeManager(reader: reader, delivery: delivery)

        let result = await harness.manager.handleSubscribe(
            invocation: makeSubscribeInvocation(),
            conversationId: "conv-1",
            agentInboxId: "agent-1"
        )

        #expect(result.status == .executionFailed)
        #expect(harness.gateway.enableCalls.isEmpty)
    }

    @Test("subscribe persists the anchor only when the reader returns one")
    func subscribePersistsAnchorWhenPresent() async throws {
        let reader = RecordingReader()
        let delivery = RecordingDelivery()
        let harness = makeManager(reader: reader, delivery: delivery)

        _ = await harness.manager.handleSubscribe(
            invocation: makeSubscribeInvocation(),
            conversationId: "conv-1",
            agentInboxId: "agent-1"
        )

        let rows = try await harness.store.allSubscriptions()
        #expect(rows.first?.anchor == nil)
    }
}
