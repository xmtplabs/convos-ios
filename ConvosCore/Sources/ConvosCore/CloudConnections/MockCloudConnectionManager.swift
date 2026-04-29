import Combine
import Foundation

public final class MockCloudConnectionManager: CloudConnectionManagerProtocol, Sendable {
    public init() {}

    public func connect(serviceId: String) async throws -> CloudConnection {
        // Derive the display name from the input serviceId via the same helper
        // the real CloudConnectionManager uses, so test assertions on per-service
        // naming reflect production behavior.
        CloudConnection(
            id: "mock-\(UUID().uuidString)",
            serviceId: serviceId,
            serviceName: CloudConnectionServiceNaming.displayName(for: serviceId),
            provider: .composio,
            composioEntityId: "convos_mock",
            composioConnectionId: "mock_conn",
            status: .active,
            connectedAt: Date()
        )
    }

    public func disconnect(connectionId: String) async throws {}

    public func refreshConnections() async throws -> [CloudConnection] {
        []
    }
}

public final class MockConnectionRepository: CloudConnectionRepositoryProtocol, Sendable {
    public init() {}

    public func connections() async throws -> [CloudConnection] {
        []
    }

    public func connectionsPublisher() -> AnyPublisher<[CloudConnection], Never> {
        Just([]).eraseToAnyPublisher()
    }

    public func grants(for conversationId: String) async throws -> [CloudConnectionGrant] {
        []
    }

    public func grantsPublisher(for conversationId: String) -> AnyPublisher<[CloudConnectionGrant], Never> {
        Just([]).eraseToAnyPublisher()
    }
}

public final class MockConnectionGrantWriter: CloudConnectionGrantWriterProtocol, Sendable {
    public init() {}

    public func grantConnection(_ connectionId: String, to conversationId: String) async throws {}

    public func revokeGrant(connectionId: String, from conversationId: String) async throws {}
}
