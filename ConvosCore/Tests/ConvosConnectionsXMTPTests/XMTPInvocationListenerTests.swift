import ConvosConnections
@testable import ConvosConnectionsXMTP
import Foundation
import Testing

@Suite("XMTP invocation listener")
struct XMTPInvocationListenerTests {
    @Test("schema version mismatch delivers executionFailed and never touches the sink")
    func schemaMismatch() async throws {
        let recorder = DeliveryRecorder()
        let sink = CountingSink()
        let manager = ConnectionsManager(
            sources: [],
            sinks: [sink],
            store: InMemoryEnablementStore(),
            delivery: recorder
        )
        let listener = XMTPInvocationListener(manager: manager, delivery: recorder)

        // Decode a future-version invocation from raw JSON so we bypass the default schemaVersion.
        let futureJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "schemaVersion": 999,
            "invocationId": "future-001",
            "kind": "contacts",
            "action": { "name": "create_contact", "arguments": {} },
            "issuedAt": 0
        }
        """.data(using: .utf8)!
        let invocation = try JSONDecoder().decode(ConnectionInvocation.self, from: futureJSON)

        await listener.handle(invocation: invocation, conversationId: "conv-1")

        let results = await recorder.results()
        #expect(results.count == 1)
        #expect(results.first?.status == .executionFailed)
        #expect(results.first?.errorMessage?.contains("999") == true)
        #expect(await sink.invokeCount() == 0)
    }

    @Test("valid invocation routes through the manager")
    func validInvocation() async throws {
        let recorder = DeliveryRecorder()
        let sink = CountingSink()
        let store = InMemoryEnablementStore()
        // Enable the capability so the manager's gate passes and the sink is hit.
        await store.setEnabled(true, kind: .contacts, capability: .writeCreate, conversationId: "conv-1")

        let manager = ConnectionsManager(
            sources: [],
            sinks: [sink],
            store: store,
            delivery: recorder
        )
        let listener = XMTPInvocationListener(manager: manager, delivery: recorder)

        let invocation = ConnectionInvocation(
            invocationId: "valid-001",
            kind: .contacts,
            action: ConnectionAction(name: "create_contact", arguments: [:])
        )

        await listener.handle(invocation: invocation, conversationId: "conv-1")

        #expect(await sink.invokeCount() == 1)
        let results = await recorder.results()
        #expect(results.count == 1)
        #expect(results.first?.status == .success)
    }
}

// MARK: - Test doubles

private actor DeliveryRecorder: ConnectionDelivering {
    private var stored: [ConnectionInvocationResult] = []

    func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws {}

    func deliver(_ result: ConnectionInvocationResult, to conversationId: String) async throws {
        stored.append(result)
    }

    func results() -> [ConnectionInvocationResult] { stored }
}

private final class CountingSink: DataSink, @unchecked Sendable {
    private let state: StateBox = StateBox()

    private actor StateBox {
        var count: Int = 0
        func increment() { count += 1 }
    }

    var kind: ConnectionKind { .contacts }

    func actionSchemas() async -> [ActionSchema] {
        [
            ActionSchema(
                kind: .contacts,
                actionName: "create_contact",
                capability: .writeCreate,
                summary: "test",
                inputs: [],
                outputs: []
            ),
        ]
    }

    func authorizationStatus() async -> ConnectionAuthorizationStatus { .authorized }

    @discardableResult
    func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .authorized }

    func invoke(_ invocation: ConnectionInvocation) async -> ConnectionInvocationResult {
        await state.increment()
        return ConnectionInvocationResult(
            invocationId: invocation.invocationId,
            kind: invocation.kind,
            actionName: invocation.action.name,
            status: .success
        )
    }

    func invokeCount() async -> Int { await state.count }
}
