import Combine
import Foundation

public final class MockConnectionManager: ConnectionManagerProtocol, Sendable {
    public init() {}

    public func connect(serviceId: String) async throws -> Connection {
        // Derive the display name from the input serviceId via the same helper
        // the real ConnectionManager uses, so test assertions on per-service
        // naming reflect production behavior.
        Connection(
            id: "mock-\(UUID().uuidString)",
            serviceId: serviceId,
            serviceName: ConnectionServiceNaming.displayName(for: serviceId),
            provider: .composio,
            composioEntityId: "convos_mock",
            composioConnectionId: "mock_conn",
            status: .active,
            connectedAt: Date()
        )
    }

    public func disconnect(connectionId: String) async throws {}

    public func refreshConnections() async throws -> [Connection] {
        []
    }
}

public final class MockConnectionRepository: ConnectionRepositoryProtocol, Sendable {
    public init() {}

    public func connections() async throws -> [Connection] {
        []
    }

    public func connectionsPublisher() -> AnyPublisher<[Connection], Never> {
        Just([]).eraseToAnyPublisher()
    }

    public func grants(for conversationId: String) async throws -> [ConnectionGrant] {
        []
    }

    public func grantsPublisher(for conversationId: String) -> AnyPublisher<[ConnectionGrant], Never> {
        Just([]).eraseToAnyPublisher()
    }
}

public final class MockConnectionGrantWriter: ConnectionGrantWriterProtocol, Sendable {
    public init() {}

    public func grantConnection(_ connectionId: String, to conversationId: String) async throws {}

    public func revokeGrant(connectionId: String, from conversationId: String) async throws {}
}
