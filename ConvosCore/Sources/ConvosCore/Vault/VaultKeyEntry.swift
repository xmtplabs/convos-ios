import Foundation

public struct VaultKeyEntry: Sendable, Equatable {
    public let inboxId: String
    public let clientId: String
    public let conversationId: String
    public let privateKeyData: Data
    public let databaseKey: Data

    public init(
        inboxId: String,
        clientId: String,
        conversationId: String,
        privateKeyData: Data,
        databaseKey: Data
    ) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.conversationId = conversationId
        self.privateKeyData = privateKeyData
        self.databaseKey = databaseKey
    }
}
