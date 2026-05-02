import ConvosConnections
@testable import ConvosCore
import Foundation
import Testing

@Suite("HealthInvocationRouter")
struct HealthInvocationRouterTests {
    private static let conversationId: String = "conv-1"
    private static let agentInboxId: String = "agent-1"

    // MARK: - intercepts(_:)

    @Test("intercepts only health subscribe and unsubscribe actions")
    func intercepts() {
        #expect(HealthInvocationRouter.intercepts(
            invocation(actionName: HealthActionSchemas.subscribeBackgroundDelivery.actionName)
        ))
        #expect(HealthInvocationRouter.intercepts(
            invocation(actionName: HealthActionSchemas.unsubscribeBackgroundDelivery.actionName)
        ))
        #expect(!HealthInvocationRouter.intercepts(
            invocation(actionName: HealthActionSchemas.fetchSamples.actionName)
        ))
        #expect(!HealthInvocationRouter.intercepts(
            ConnectionInvocation(
                invocationId: "id",
                kind: .calendar,
                action: ConnectionAction(
                    name: HealthActionSchemas.subscribeBackgroundDelivery.actionName,
                    arguments: [:]
                )
            )
        ))
    }

    // MARK: - capability gate

    @Test("returns capabilityNotEnabled and delivers result without touching the manager when read is off")
    func capabilityGateDenies() async throws {
        let harness = await Harness.make(readEnabled: false)

        let result = await harness.router.route(
            invocation: harness.subscribeInvocation,
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId
        )

        #expect(result.status == .capabilityNotEnabled)
        let delivered = await harness.delivery.results()
        #expect(delivered.count == 1)
        #expect(delivered.first?.status == .capabilityNotEnabled)

        let storedRows = try await harness.subscriptionStore.allSubscriptions()
        #expect(storedRows.isEmpty)
        #expect(harness.gateway.enableCalls.isEmpty)
    }

    // MARK: - subscribe routing

    @Test("subscribe persists row, applies frequency, delivers success result, and triggers observer registration")
    func subscribeRoutesAndAppliesObserver() async throws {
        let harness = await Harness.make(readEnabled: true)

        let result = await harness.router.route(
            invocation: harness.subscribeInvocation,
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId
        )

        #expect(result.status == .success)
        #expect(result.actionName == HealthActionSchemas.subscribeBackgroundDelivery.actionName)

        let storedRows = try await harness.subscriptionStore.allSubscriptions()
        #expect(storedRows.count == 1)
        #expect(storedRows.first?.conversationId == Self.conversationId)
        #expect(storedRows.first?.agentInboxId == Self.agentInboxId)
        #expect(storedRows.first?.typeIdentifier == .stepCount)

        // applyEffectiveFrequency runs once during handleSubscribe and again from
        // routine.applyForType after the result is delivered.
        #expect(harness.gateway.enableCalls.count >= 1)
        #expect(harness.gateway.enableCalls.allSatisfy { $0.0 == .stepCount })

        let delivered = await harness.delivery.results()
        #expect(delivered.contains { $0.status == .success })

        let registered = await harness.registrar.startedTypesSnapshot()
        #expect(registered.contains(.stepCount))
    }

    // MARK: - unsubscribe routing

    @Test("unsubscribe removes row, disables gateway, stops observer, and delivers success result")
    func unsubscribeRoutesAndStopsObserver() async throws {
        let harness = await Harness.make(readEnabled: true)
        // Pre-seed a subscription so unsubscribe has something to remove.
        _ = await harness.router.route(
            invocation: harness.subscribeInvocation,
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId
        )
        await harness.delivery.reset()
        harness.gateway.reset()

        let result = await harness.router.route(
            invocation: harness.unsubscribeInvocation,
            conversationId: Self.conversationId,
            agentInboxId: Self.agentInboxId
        )

        #expect(result.status == .success)
        #expect(result.actionName == HealthActionSchemas.unsubscribeBackgroundDelivery.actionName)

        let storedRows = try await harness.subscriptionStore.allSubscriptions()
        #expect(storedRows.isEmpty)
        #expect(harness.gateway.disableCalls.contains(.stepCount))

        let stopped = await harness.registrar.stoppedTypesSnapshot()
        #expect(stopped.contains(.stepCount))
    }

    // MARK: - helpers

    private struct Harness {
        let router: HealthInvocationRouter
        let enablementStore: InMemoryEnablementStore
        let subscriptionStore: InMemoryHealthBackgroundSubscriptionStore
        let gateway: RecordingGateway
        let registrar: RecordingRegistrar
        let delivery: RecordingDelivery
        let subscribeInvocation: ConnectionInvocation
        let unsubscribeInvocation: ConnectionInvocation

        static func make(readEnabled: Bool, tests: HealthInvocationRouterTests = .init()) async -> Harness {
            let enablementStore = readEnabled
                ? InMemoryEnablementStore(initial: [
                    Enablement(kind: .health, capability: .read, conversationId: HealthInvocationRouterTests.conversationId),
                ])
                : InMemoryEnablementStore()

            let subscriptionStore = InMemoryHealthBackgroundSubscriptionStore()
            let gateway = RecordingGateway()
            let registrar = RecordingRegistrar()
            let delivery = RecordingDelivery()

            let manager = HealthBackgroundSubscriptionManager(
                store: subscriptionStore,
                gateway: gateway,
                reader: nil,
                delivery: delivery
            )
            let routine = HealthBackgroundObserverRoutine(
                store: subscriptionStore,
                manager: manager,
                registrar: registrar,
                reader: NoopDeltaReader(),
                delivery: delivery
            )
            let router = HealthInvocationRouter(
                enablementStore: enablementStore,
                manager: manager,
                routine: routine,
                delivery: delivery
            )
            return Harness(
                router: router,
                enablementStore: enablementStore,
                subscriptionStore: subscriptionStore,
                gateway: gateway,
                registrar: registrar,
                delivery: delivery,
                subscribeInvocation: tests.subscribeInvocation(),
                unsubscribeInvocation: tests.unsubscribeInvocation()
            )
        }
    }

    private func invocation(
        actionName: String,
        kind: ConnectionKind = .health,
        arguments: [String: ArgumentValue] = [:]
    ) -> ConnectionInvocation {
        ConnectionInvocation(
            invocationId: "inv-\(actionName)",
            kind: kind,
            action: ConnectionAction(name: actionName, arguments: arguments)
        )
    }

    private func subscribeInvocation() -> ConnectionInvocation {
        invocation(
            actionName: HealthActionSchemas.subscribeBackgroundDelivery.actionName,
            arguments: [
                "typeIdentifier": .enumValue(HealthSampleType.stepCount.rawValue),
                "frequency": .enumValue(HealthBackgroundFrequency.hourly.rawValue),
                "historyDays": .int(7),
            ]
        )
    }

    private func unsubscribeInvocation() -> ConnectionInvocation {
        invocation(
            actionName: HealthActionSchemas.unsubscribeBackgroundDelivery.actionName,
            arguments: [
                "typeIdentifier": .enumValue(HealthSampleType.stepCount.rawValue),
            ]
        )
    }
}

// MARK: - Test doubles

private actor RecordingDelivery: ConnectionDelivering {
    private var stored: [ConnectionInvocationResult] = []

    func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws {}

    func deliver(_ result: ConnectionInvocationResult, to conversationId: String) async throws {
        stored.append(result)
    }

    func results() -> [ConnectionInvocationResult] { stored }

    func reset() { stored.removeAll() }
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

    func reset() {
        enableCalls.removeAll()
        disableCalls.removeAll()
    }
}

private actor RecordingRegistrar: HealthBackgroundObserverRegistrar {
    private var startedTypes: [HealthSampleType] = []
    private var stoppedTypes: [HealthSampleType] = []

    func start(typeIdentifier: HealthSampleType, onFire: @escaping @Sendable () async -> Void) async throws {
        startedTypes.append(typeIdentifier)
    }

    func stop(typeIdentifier: HealthSampleType) async {
        stoppedTypes.append(typeIdentifier)
    }

    func startedTypesSnapshot() -> [HealthSampleType] { startedTypes }
    func stoppedTypesSnapshot() -> [HealthSampleType] { stoppedTypes }
}

private struct NoopDeltaReader: HealthDeltaReader {
    func delta(typeIdentifier: HealthSampleType, anchor: Data?) async throws -> HealthDeltaResult {
        HealthDeltaResult(samples: [], anchor: nil)
    }
}
