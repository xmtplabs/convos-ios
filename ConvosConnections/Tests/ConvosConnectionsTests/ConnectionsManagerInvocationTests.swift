@testable import ConvosConnections
import Foundation
import Testing

@Suite("ConnectionsManager invocation routing")
struct ConnectionsManagerInvocationTests {
    @Test("returns unknownAction when no sink is registered for the kind")
    func unknownActionForMissingSink() async {
        let manager = makeManager(sinks: [])
        let result = await manager.handleInvocation(
            makeCreateEventInvocation(),
            from: "conv-1"
        )
        #expect(result.status == .unknownAction)
    }

    @Test("returns unknownAction when sink doesn't know the action")
    func unknownActionForMissingActionName() async {
        let sink = TestSink(kind: .calendar, schemas: [CalendarActionSchemas.createEvent])
        let manager = makeManager(sinks: [sink])
        let invocation = ConnectionInvocation(
            invocationId: "x",
            kind: .calendar,
            action: ConnectionAction(name: "not_a_real_action", arguments: [:])
        )
        let result = await manager.handleInvocation(invocation, from: "conv-1")
        #expect(result.status == .unknownAction)
    }

    @Test("returns capabilityNotEnabled when capability is off")
    func capabilityNotEnabled() async {
        let sink = TestSink(kind: .calendar, schemas: CalendarActionSchemas.all, response: .init(status: .success))
        let manager = makeManager(sinks: [sink])
        let result = await manager.handleInvocation(makeCreateEventInvocation(), from: "conv-1")
        #expect(result.status == .capabilityNotEnabled)
    }

    @Test("calls sink.invoke and delivers result when capability is enabled")
    func happyPathInvokesSinkAndDelivers() async {
        let sink = TestSink(
            kind: .calendar,
            schemas: CalendarActionSchemas.all,
            response: .init(status: .success, result: ["eventId": .string("evt-1")])
        )
        let delivery = RecordingDelivering()
        let store = InMemoryEnablementStore()
        await store.setEnabled(true, kind: .calendar, capability: .writeCreate, conversationId: "conv-1")
        let manager = ConnectionsManager(sources: [], sinks: [sink], store: store, delivery: delivery)

        let result = await manager.handleInvocation(makeCreateEventInvocation(), from: "conv-1")
        #expect(result.status == .success)
        #expect(result.result["eventId"] == .string("evt-1"))

        let delivered = await delivery.invocationLog()
        #expect(delivered.count == 1)
        #expect(delivered.first?.conversationId == "conv-1")
    }

    @Test("returns requiresConfirmation when alwaysConfirm is on and no handler is installed")
    func requiresConfirmationWhenNoHandler() async {
        let sink = TestSink(kind: .calendar, schemas: CalendarActionSchemas.all, response: .init(status: .success))
        let store = InMemoryEnablementStore()
        await store.setEnabled(true, kind: .calendar, capability: .writeCreate, conversationId: "conv-1")
        await store.setAlwaysConfirmWrites(true, kind: .calendar, conversationId: "conv-1")
        let manager = ConnectionsManager(sources: [], sinks: [sink], store: store, delivery: RecordingDelivering())
        let result = await manager.handleInvocation(makeCreateEventInvocation(), from: "conv-1")
        #expect(result.status == .requiresConfirmation)
    }

    @Test("returns requiresConfirmation when handler responds cannotPresent")
    func requiresConfirmationOnCannotPresent() async {
        let sink = TestSink(kind: .calendar, schemas: CalendarActionSchemas.all, response: .init(status: .success))
        let store = InMemoryEnablementStore()
        await store.setEnabled(true, kind: .calendar, capability: .writeCreate, conversationId: "conv-1")
        await store.setAlwaysConfirmWrites(true, kind: .calendar, conversationId: "conv-1")
        let manager = ConnectionsManager(sources: [], sinks: [sink], store: store, delivery: RecordingDelivering())
        await manager.setConfirmationHandler(TestConfirmationHandler(decision: .cannotPresent))
        let result = await manager.handleInvocation(makeCreateEventInvocation(), from: "conv-1")
        #expect(result.status == .requiresConfirmation)
    }

    @Test("returns authorizationDenied when handler responds denied")
    func authorizationDeniedOnDenied() async {
        let sink = TestSink(kind: .calendar, schemas: CalendarActionSchemas.all, response: .init(status: .success))
        let store = InMemoryEnablementStore()
        await store.setEnabled(true, kind: .calendar, capability: .writeCreate, conversationId: "conv-1")
        await store.setAlwaysConfirmWrites(true, kind: .calendar, conversationId: "conv-1")
        let manager = ConnectionsManager(sources: [], sinks: [sink], store: store, delivery: RecordingDelivering())
        await manager.setConfirmationHandler(TestConfirmationHandler(decision: .denied))
        let result = await manager.handleInvocation(makeCreateEventInvocation(), from: "conv-1")
        #expect(result.status == .authorizationDenied)
    }

    @Test("proceeds to sink when handler approves")
    func sinkInvokedOnApproved() async {
        let sink = TestSink(
            kind: .calendar,
            schemas: CalendarActionSchemas.all,
            response: .init(status: .success, result: ["eventId": .string("evt-x")])
        )
        let store = InMemoryEnablementStore()
        await store.setEnabled(true, kind: .calendar, capability: .writeCreate, conversationId: "conv-1")
        await store.setAlwaysConfirmWrites(true, kind: .calendar, conversationId: "conv-1")
        let manager = ConnectionsManager(sources: [], sinks: [sink], store: store, delivery: RecordingDelivering())
        await manager.setConfirmationHandler(TestConfirmationHandler(decision: .approved))
        let result = await manager.handleInvocation(makeCreateEventInvocation(), from: "conv-1")
        #expect(result.status == .success)
    }

    @Test("read actions use read capability gate")
    func readActionUsesReadCapability() async {
        let readSchema = ActionSchema(
            kind: .health,
            actionName: "fetch_summary_last_24h",
            capability: .read,
            summary: "Read summary",
            inputs: [],
            outputs: []
        )
        let sink = TestSink(kind: .health, schemas: [readSchema], response: .init(status: .success))
        let store = InMemoryEnablementStore()
        let manager = ConnectionsManager(sources: [], sinks: [sink], store: store, delivery: RecordingDelivering())

        let disabled = await manager.handleInvocation(
            ConnectionInvocation(
                invocationId: "read-1",
                kind: .health,
                action: ConnectionAction(name: "fetch_summary_last_24h", arguments: [:])
            ),
            from: "conv-1"
        )
        #expect(disabled.status == .capabilityNotEnabled)

        await store.setEnabled(true, kind: .health, capability: .read, conversationId: "conv-1")
        let enabled = await manager.handleInvocation(
            ConnectionInvocation(
                invocationId: "read-2",
                kind: .health,
                action: ConnectionAction(name: "fetch_summary_last_24h", arguments: [:])
            ),
            from: "conv-1"
        )
        #expect(enabled.status == .success)
    }

    @Test("appends to recentInvocationLog")
    func recordsInvocation() async {
        let sink = TestSink(kind: .calendar, schemas: CalendarActionSchemas.all, response: .init(status: .success))
        let store = InMemoryEnablementStore()
        await store.setEnabled(true, kind: .calendar, capability: .writeCreate, conversationId: "conv-1")
        let manager = ConnectionsManager(sources: [], sinks: [sink], store: store, delivery: RecordingDelivering())
        _ = await manager.handleInvocation(makeCreateEventInvocation(), from: "conv-1")
        let log = await manager.recentInvocationLog()
        #expect(log.count == 1)
        #expect(log.first?.result.status == .success)
    }

    @Test("records delivery failure when deliver(result:) is unimplemented")
    func recordsDeliveryFailure() async {
        let sink = TestSink(kind: .calendar, schemas: CalendarActionSchemas.all, response: .init(status: .success))
        let store = InMemoryEnablementStore()
        await store.setEnabled(true, kind: .calendar, capability: .writeCreate, conversationId: "conv-1")
        let delivery = UnimplementedResultDelivering()
        let manager = ConnectionsManager(sources: [], sinks: [sink], store: store, delivery: delivery)
        let result = await manager.handleInvocation(makeCreateEventInvocation(), from: "conv-1")
        #expect(result.status == .success) // sink still executes
        let log = await manager.recentInvocationLog()
        #expect(log.first?.resultDeliveryError != nil)
    }

    // MARK: - Helpers

    private func makeManager(sinks: [DataSink]) -> ConnectionsManager {
        ConnectionsManager(
            sources: [],
            sinks: sinks,
            store: InMemoryEnablementStore(),
            delivery: RecordingDelivering()
        )
    }

    private func makeCreateEventInvocation() -> ConnectionInvocation {
        ConnectionInvocation(
            invocationId: "req-1",
            kind: .calendar,
            action: ConnectionAction(
                name: "create_event",
                arguments: ["title": .string("t")]
            )
        )
    }
}

// MARK: - Test doubles

private actor TestSink: DataSink {
    struct Response: Sendable {
        let status: ConnectionInvocationResult.Status
        let result: [String: ArgumentValue]
        let errorMessage: String?

        init(
            status: ConnectionInvocationResult.Status,
            result: [String: ArgumentValue] = [:],
            errorMessage: String? = nil
        ) {
            self.status = status
            self.result = result
            self.errorMessage = errorMessage
        }
    }

    let kind: ConnectionKind
    private let schemas: [ActionSchema]
    private let response: Response

    init(kind: ConnectionKind, schemas: [ActionSchema], response: Response = .init(status: .success)) {
        self.kind = kind
        self.schemas = schemas
        self.response = response
    }

    func actionSchemas() async -> [ActionSchema] { schemas }

    func authorizationStatus() async -> ConnectionAuthorizationStatus { .authorized }

    func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .authorized }

    func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: invocation.kind,
            actionName: invocation.action.name,
            status: response.status,
            result: response.result,
            errorMessage: response.errorMessage
        )
    }
}

private actor RecordingDelivering: ConnectionDelivering {
    struct Entry: Sendable, Equatable {
        let result: ConnectionInvocationResult
        let conversationId: String
    }

    private var log: [Entry] = []

    func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws {}

    func deliver(_ result: ConnectionInvocationResult, to conversationId: String) async throws {
        log.append(Entry(result: result, conversationId: conversationId))
    }

    func invocationLog() -> [Entry] { log }
}

private struct UnimplementedResultDelivering: ConnectionDelivering {
    func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws {}
    // No override for deliver(_:result:) — inherits the throwing default.
}

private struct TestConfirmationHandler: ConfirmationHandling {
    let decision: ConfirmationDecision
    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision { decision }
}
