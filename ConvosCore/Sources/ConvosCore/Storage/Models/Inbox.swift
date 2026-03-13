import Foundation

public struct Inbox: Codable, Hashable, Identifiable {
    public var id: String { inboxId }
    public let inboxId: String
    public let clientId: String
    public let createdAt: Date
    public let isVault: Bool
    public let installationId: String?

    public init(
        inboxId: String,
        clientId: String,
        createdAt: Date = Date(),
        isVault: Bool = false,
        installationId: String? = nil
    ) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.createdAt = createdAt
        self.isVault = isVault
        self.installationId = installationId
    }
}
