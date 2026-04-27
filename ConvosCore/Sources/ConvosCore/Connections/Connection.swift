import Foundation

public enum ConnectionStatus: String, Codable, Sendable {
    case active, expired, revoked
}

public enum ConnectionProvider: String, Codable, Sendable {
    case composio
}

public struct Connection: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let serviceId: String
    public let serviceName: String
    public let provider: ConnectionProvider
    public let composioEntityId: String
    public let composioConnectionId: String
    public let status: ConnectionStatus
    public let connectedAt: Date

    public init(
        id: String,
        serviceId: String,
        serviceName: String,
        provider: ConnectionProvider,
        composioEntityId: String,
        composioConnectionId: String,
        status: ConnectionStatus,
        connectedAt: Date
    ) {
        self.id = id
        self.serviceId = serviceId
        self.serviceName = serviceName
        self.provider = provider
        self.composioEntityId = composioEntityId
        self.composioConnectionId = composioConnectionId
        self.status = status
        self.connectedAt = connectedAt
    }
}
