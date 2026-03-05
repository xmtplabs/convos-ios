import Foundation

public struct ConversationKeyInfo: Sendable {
    public let conversationId: String
    public let inboxId: String
    public let clientId: String
    public let privateKeyData: Data
    public let databaseKey: Data

    public init(
        conversationId: String,
        inboxId: String,
        clientId: String,
        privateKeyData: Data,
        databaseKey: Data
    ) {
        self.conversationId = conversationId
        self.inboxId = inboxId
        self.clientId = clientId
        self.privateKeyData = privateKeyData
        self.databaseKey = databaseKey
    }
}

public protocol VaultKeyShareNotifier: Sendable {
    func conversationKeyCreated(_ keyInfo: ConversationKeyInfo)
}
