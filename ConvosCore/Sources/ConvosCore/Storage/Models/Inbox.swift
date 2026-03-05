import Foundation

public struct Inbox: Codable, Hashable, Identifiable {
    public var id: String { inboxId }
    public let inboxId: String
    public let clientId: String
    public let createdAt: Date
    public let isVault: Bool

    public init(inboxId: String, clientId: String, createdAt: Date = Date(), isVault: Bool = false) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.createdAt = createdAt
        self.isVault = isVault
    }
}
