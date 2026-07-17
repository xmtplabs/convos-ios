import Foundation

public enum CloudConnectionStatus: String, Codable, Sendable {
    case active, expired, revoked
}

public enum CloudConnectionProvider: String, Codable, Sendable {
    case composio
}

public struct CloudConnection: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let serviceId: String
    public let serviceName: String
    public let provider: CloudConnectionProvider
    public let composioEntityId: String
    public let composioConnectionId: String
    public let status: CloudConnectionStatus
    public let connectedAt: Date

    public init(
        id: String,
        serviceId: String,
        serviceName: String,
        provider: CloudConnectionProvider,
        composioEntityId: String,
        composioConnectionId: String,
        status: CloudConnectionStatus,
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
