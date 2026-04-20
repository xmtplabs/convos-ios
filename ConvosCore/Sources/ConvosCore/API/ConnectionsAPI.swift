import Foundation

public enum ConnectionsAPI {
    public struct InitiateResponse: Codable, Sendable {
        public let connectionRequestId: String
        public let redirectUrl: String
    }

    public struct CompleteResponse: Codable, Sendable {
        public let connectionId: String
        public let serviceId: String
        public let serviceName: String
        public let composioEntityId: String
        public let composioConnectionId: String
        public let status: String
    }

    public struct ConnectionResponse: Codable, Sendable {
        public let id: String
        public let serviceId: String
        public let serviceName: String
        public let composioEntityId: String
        public let composioConnectionId: String
        public let status: String
        public let connectedAt: String
    }
}
