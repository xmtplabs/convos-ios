@testable import ConvosConnections
import Foundation
import Testing

@Suite("HealthBackgroundObserverRoutine")
struct HealthBackgroundObserverRoutineTests {
    private final class RecordingRegistrar: HealthBackgroundObserverRegistrar, @unchecked Sendable {
        var startedTypes: [HealthSampleType] = []
        var stoppedTypes: [HealthSampleType] = []
        var fireHandlers: [HealthSampleType: () async -> Void] = [:]

        func start(typeIdentifier: HealthSampleType, onFire: @escaping @Sendable () async -> Void) async throws {
            startedTypes.append(typeIdentifier)
            fireHandlers[typeIdentifier] = onFire
        }

        func stop(typeIdentifier: HealthSampleType) async {
            stoppedTypes.append(typeIdentifier)
            fireHandlers[typeIdentifier] = nil
        }

        func fire(_ typeIdentifier: HealthSampleType) async {
            await fireHandlers[typeIdentifier]?()
        }
    }

    private final class RecordingDeltaReader: HealthDeltaReader, @unchecked Sendable {
        struct Call: Equatable {
            let typeIdentifier: HealthSampleType
            let anchor: Data?
        }

        var calls: [Call] = []
        var responses: [HealthSampleType: [HealthDeltaResult]] = [:]

        func delta(typeIdentifier: HealthSampleType, anchor: Data?) async throws -> HealthDeltaResult {
            calls.append(Call(typeIdentifier: typeIdentifier, anchor: anchor))
            if var queue = responses[typeIdentifier], !queue.isEmpty {
                let next = queue.removeFirst()
                responses[typeIdentifier] = queue
                return next
            }
            return HealthDeltaResult(samples: [], anchor: nil)
        }
    }

    private final class RecordingDelivery: ConnectionDelivering, @unchecked Sendable {
        struct PayloadDelivery: Equatable {
            let payload: ConnectionPayload
            let conversationId: String
        }

        var payloadCalls: [PayloadDelivery] = []

        func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws {
            payloadCalls.append(PayloadDelivery(payload: payload, conversationId: conversationId))
        }

        func deliver(_ result: ConnectionInvocationResult, to conversationId: String) async throws {}
    }

    private final class RecordingGateway: HealthBackgroundDeliveryGateway, @unchecked Sendable {
        var enableCalls: [(HealthSampleType, HealthBackgroundFrequency)] = []
        var disableCalls: [HealthSampleType] = []

        func setBackgroundDelivery(typeIdentifier: HealthSampleType, frequency: HealthBackgroundFrequency) async throws {
            enableCalls.append((typeIdentifier, frequency))
        }

        func disableBackgroundDelivery(typeIdentifier: HealthSampleType) async throws {
            disableCalls.append(typeIdentifier)
        }
    }

    private static let fixedNow: Date = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSubscription(
        conversationId: String = "conv-1",
        agentInboxId: String = "agent-1",
        type: HealthSampleType = .stepCount,
        frequency: HealthBackgroundFrequency = .hourly,
        anchor: Data? = nil
    ) -> HealthBackgroundSubscription {
        HealthBackgroundSubscription(
            conversationId: conversationId,
            agentInboxId: agentInboxId,
            typeIdentifier: type,
            frequency: frequency,
            historyDays: 7,
            anchor: anchor
        )
    }

    private func makeSample(
        type: HealthSampleType = .stepCount,
        offset: TimeInterval = -300,
        value: Double = 100
    ) -> HealthSample {
        HealthSample(
            type: type,
            startDate: Self.fixedNow.addingTimeInterval(offset),
            endDate: Self.fixedNow.addingTimeInterval(offset),
            value: value,
            unit: "count"
        )
    }

    private struct Harness {
        let routine: HealthBackgroundObserverRoutine
        let store: InMemoryHealthBackgroundSubscriptionStore
        let manager: HealthBackgroundSubscriptionManager
        let registrar: RecordingRegistrar
        let reader: RecordingDeltaReader
        let delivery: RecordingDelivery
        let gateway: RecordingGateway
    }

    private func makeRoutine(
        store: InMemoryHealthBackgroundSubscriptionStore = InMemoryHealthBackgroundSubscriptionStore()
    ) -> Harness {
        let registrar = RecordingRegistrar()
        let reader = RecordingDeltaReader()
        let delivery = RecordingDelivery()
        let gateway = RecordingGateway()
        let manager = HealthBackgroundSubscriptionManager(store: store, gateway: gateway)
        let routine = HealthBackgroundObserverRoutine(
            store: store,
            manager: manager,
            registrar: registrar,
            reader: reader,
            delivery: delivery,
            now: { Self.fixedNow }
        )
        return Harness(
            routine: routine,
            store: store,
            manager: manager,
            registrar: registrar,
            reader: reader,
            delivery: delivery,
            gateway: gateway
        )
    }

    // MARK: - start

    @Test("start registers one observer per unique type and applies the effective frequency for each")
    func startDeduplicatesByType() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore(initial: [
            makeSubscription(conversationId: "conv-1", type: .stepCount, frequency: .hourly),
            makeSubscription(conversationId: "conv-2", type: .stepCount, frequency: .daily),
            makeSubscription(conversationId: "conv-1", type: .sleepAnalysis, frequency: .weekly),
        ])
        let harness = makeRoutine(store: store)

        try await harness.routine.start()

        #expect(Set(harness.registrar.startedTypes) == [.stepCount, .sleepAnalysis])
        #expect(Set(harness.gateway.enableCalls.map(\.0)) == [.stepCount, .sleepAnalysis])
        let stepCallFrequency = harness.gateway.enableCalls.first(where: { $0.0 == .stepCount })?.1
        #expect(stepCallFrequency == .hourly)
    }

    @Test("start is idempotent")
    func startIdempotent() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore(initial: [makeSubscription()])
        let harness = makeRoutine(store: store)

        try await harness.routine.start()
        try await harness.routine.start()

        #expect(harness.registrar.startedTypes.count == 1)
    }

    @Test("start with no subscriptions registers no observers")
    func startEmpty() async throws {
        let harness = makeRoutine()
        try await harness.routine.start()
        #expect(harness.registrar.startedTypes.isEmpty)
        #expect(harness.gateway.enableCalls.isEmpty)
    }

    // MARK: - applyForType

    @Test("applyForType registers the observer when at least one subscription exists")
    func applyAddsObserver() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore()
        let harness = makeRoutine(store: store)
        try await store.upsert(makeSubscription(type: .sleepAnalysis, frequency: .weekly))

        try await harness.routine.applyForType(.sleepAnalysis)

        #expect(harness.registrar.startedTypes == [.sleepAnalysis])
        #expect(harness.gateway.enableCalls.map(\.0) == [.sleepAnalysis])
        #expect(harness.gateway.enableCalls.map(\.1) == [.weekly])
    }

    @Test("applyForType stops the observer and disables the gateway when the last subscription leaves")
    func applyRemovesObserver() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore(initial: [makeSubscription()])
        let harness = makeRoutine(store: store)
        try await harness.routine.start()

        try await store.delete(conversationId: "conv-1", agentInboxId: "agent-1", typeIdentifier: .stepCount)
        try await harness.routine.applyForType(.stepCount)

        #expect(harness.registrar.stoppedTypes == [.stepCount])
        #expect(harness.gateway.disableCalls == [.stepCount])
    }

    // MARK: - handleObserverFired

    @Test("observer fire emits one ConnectionPayload per subscription on the type and advances anchors")
    func observerFireFansOut() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore(initial: [
            makeSubscription(conversationId: "conv-A", agentInboxId: "agent-1", type: .stepCount),
            makeSubscription(conversationId: "conv-B", agentInboxId: "agent-2", type: .stepCount),
            makeSubscription(conversationId: "conv-A", agentInboxId: "agent-1", type: .sleepAnalysis),
        ])
        let harness = makeRoutine(store: store)
        harness.reader.responses[.stepCount] = [
            HealthDeltaResult(samples: [makeSample(value: 100)], anchor: Data([0xAA])),
            HealthDeltaResult(samples: [makeSample(value: 200)], anchor: Data([0xBB])),
        ]

        await harness.routine.handleObserverFired(typeIdentifier: .stepCount)

        #expect(Set(harness.delivery.payloadCalls.map(\.conversationId)) == ["conv-A", "conv-B"])
        #expect(harness.delivery.payloadCalls.count == 2)
        #expect(harness.reader.calls.count == 2)
        #expect(harness.reader.calls.allSatisfy { $0.typeIdentifier == .stepCount })

        let updated = try await store.allSubscriptions()
        let stepRows = updated.filter { $0.typeIdentifier == .stepCount }
        let anchors = Set(stepRows.compactMap(\.anchor))
        #expect(anchors == [Data([0xAA]), Data([0xBB])])
    }

    @Test("observer fire skips delivery when the delta has no new samples but still advances the anchor")
    func observerFireEmptyDeltaAdvancesAnchorOnly() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore(initial: [makeSubscription()])
        let harness = makeRoutine(store: store)
        harness.reader.responses[.stepCount] = [
            HealthDeltaResult(samples: [], anchor: Data([0x99])),
        ]

        await harness.routine.handleObserverFired(typeIdentifier: .stepCount)

        #expect(harness.delivery.payloadCalls.isEmpty)
        let rows = try await store.allSubscriptions()
        #expect(rows.first?.anchor == Data([0x99]))
    }

    @Test("observer fire passes the row's saved anchor through to the delta reader")
    func observerForwardsAnchor() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore(initial: [
            makeSubscription(anchor: Data([0x42])),
        ])
        let harness = makeRoutine(store: store)
        harness.reader.responses[.stepCount] = [
            HealthDeltaResult(samples: [makeSample()], anchor: Data([0x43])),
        ]

        await harness.routine.handleObserverFired(typeIdentifier: .stepCount)

        #expect(harness.reader.calls.first?.anchor == Data([0x42]))
    }

    @Test("registrar onFire is wired through start() so iOS wake-ups reach handleObserverFired")
    func registrarFireWired() async throws {
        let store = InMemoryHealthBackgroundSubscriptionStore(initial: [makeSubscription()])
        let harness = makeRoutine(store: store)
        try await harness.routine.start()
        harness.reader.responses[.stepCount] = [
            HealthDeltaResult(samples: [makeSample()], anchor: Data([0x77])),
        ]

        await harness.registrar.fire(.stepCount)

        #expect(harness.delivery.payloadCalls.count == 1)
    }
}
