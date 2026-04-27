@testable import ConvosConnections
import Foundation
import Testing

@Suite("ConnectionsManager")
struct ConnectionsManagerTests {
    @Test("emitted payload is fanned out to every enabled conversation")
    func emitFansOut() async throws {
        let source = TestDataSource(kind: .health)
        let store = InMemoryEnablementStore()
        let delivery = RecordingDelivering()

        await store.setEnabled(true, kind: .health, conversationId: "conv-a")
        await store.setEnabled(true, kind: .health, conversationId: "conv-b")

        let manager = ConnectionsManager(sources: [source], store: store, delivery: delivery)
        try await manager.startSource(kind: .health)

        let payload = Self.makeHealthPayload()
        await source.emit(payload)
        try await Task.sleep(nanoseconds: 50_000_000) // let manager process

        let log = await delivery.snapshot()
        #expect(log.count == 2)
        #expect(Set(log.map(\.conversationId)) == ["conv-a", "conv-b"])
        #expect(log.allSatisfy { $0.payload == payload })
    }

    @Test("payload with no enabled conversations is recorded but not delivered")
    func recordsWithoutDelivering() async throws {
        let source = TestDataSource(kind: .health)
        let store = InMemoryEnablementStore()
        let delivery = RecordingDelivering()
        let manager = ConnectionsManager(sources: [source], store: store, delivery: delivery)
        try await manager.startSource(kind: .health)

        let payload = Self.makeHealthPayload()
        await source.emit(payload)
        try await Task.sleep(nanoseconds: 50_000_000)

        let log = await delivery.snapshot()
        let recent = await manager.recentPayloadLog()
        #expect(log.isEmpty)
        #expect(recent.count == 1)
        #expect(recent.first?.fanOutConversationIds.isEmpty == true)
    }

    @Test("toggling enablement is reflected through manager API")
    func togglePropagates() async {
        let source = TestDataSource(kind: .health)
        let store = InMemoryEnablementStore()
        let delivery = RecordingDelivering()
        let manager = ConnectionsManager(sources: [source], store: store, delivery: delivery)

        let before = await manager.isEnabled(.health, conversationId: "x")
        #expect(before == false)

        await manager.setEnabled(true, kind: .health, conversationId: "x")
        let after = await manager.isEnabled(.health, conversationId: "x")
        #expect(after == true)

        let list = await manager.enabledConversationIds(for: .health)
        #expect(list == ["x"])
    }

    @Test("unknown kind returns unavailable and does not throw on start")
    func unknownKindIsUnavailable() async throws {
        let store = InMemoryEnablementStore()
        let delivery = RecordingDelivering()
        let manager = ConnectionsManager(sources: [], store: store, delivery: delivery)

        let status = await manager.authorizationStatus(for: .health)
        #expect(status == .unavailable)

        try await manager.startSource(kind: .health) // should be no-op
    }

    private static func makeHealthPayload() -> ConnectionPayload {
        ConnectionPayload(
            source: .health,
            body: .health(
                HealthPayload(
                    summary: "test",
                    samples: [],
                    rangeStart: Date(),
                    rangeEnd: Date()
                )
            )
        )
    }
}

/// Minimal `DataSource` that lets tests trigger emissions manually.
private actor TestDataSource: DataSource {
    let kind: ConnectionKind
    private var emitter: ConnectionPayloadEmitter?

    init(kind: ConnectionKind) {
        self.kind = kind
    }

    func authorizationStatus() async -> ConnectionAuthorizationStatus { .authorized }

    func requestAuthorization() async throws -> ConnectionAuthorizationStatus { .authorized }

    func start(emit: @escaping ConnectionPayloadEmitter) async throws {
        emitter = emit
    }

    func stop() async {
        emitter = nil
    }

    func emit(_ payload: ConnectionPayload) {
        emitter?(payload)
    }
}

/// `ConnectionDelivering` that records every attempt.
private actor RecordingDelivering: ConnectionDelivering {
    struct Entry: Sendable, Equatable {
        let payload: ConnectionPayload
        let conversationId: String
    }

    private var log: [Entry] = []

    func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws {
        log.append(Entry(payload: payload, conversationId: conversationId))
    }

    func snapshot() -> [Entry] { log }
}
