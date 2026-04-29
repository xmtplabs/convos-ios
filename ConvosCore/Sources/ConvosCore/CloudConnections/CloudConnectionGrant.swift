import Foundation

public struct CloudConnectionGrant: Codable, Sendable, Hashable {
    public let connectionId: String
    public let conversationId: String
    public let serviceId: String
    public let grantedAt: Date

    public init(
        connectionId: String,
        conversationId: String,
        serviceId: String,
        grantedAt: Date
    ) {
        self.connectionId = connectionId
        self.conversationId = conversationId
        self.serviceId = serviceId
        self.grantedAt = grantedAt
    }
}
