import Foundation
@preconcurrency import XMTPiOS

public struct InboxKeyInfo: Sendable {
    public let inboxId: String
    public let clientId: String
    public let conversationId: String
    public let privateKeyData: Data
    public let databaseKey: Data

    public init(inboxId: String, clientId: String, conversationId: String, privateKeyData: Data, databaseKey: Data) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.conversationId = conversationId
        self.privateKeyData = privateKeyData
        self.databaseKey = databaseKey
    }
}

public protocol VaultServiceProtocol: Sendable {
    func startVault(signingKey: SigningKey, options: ClientOptions) async throws
    func stopVault() async
    func pauseVault() async
    func resumeVault() async
    func unpairSelf() async throws
    func broadcastConversationDeleted(inboxId: String, clientId: String) async
}

public extension Notification.Name {
    static let vaultDidImportInbox: Notification.Name = .init("ConvosVaultDidImportInbox")
    static let vaultDidDeleteConversation: Notification.Name = .init("ConvosVaultDidDeleteConversation")
    static let vaultDidReceiveKeyBundle: Notification.Name = .init("ConvosVaultDidReceiveKeyBundle")
    static let vaultPairingError: Notification.Name = .init("ConvosVaultPairingError")
    static let vaultDidReceivePin: Notification.Name = .init("ConvosVaultDidReceivePin")
    static let vaultDidEnterBackground: Notification.Name = .init("ConvosVaultDidEnterBackground")
    static let vaultWillEnterForeground: Notification.Name = .init("ConvosVaultWillEnterForeground")
}
