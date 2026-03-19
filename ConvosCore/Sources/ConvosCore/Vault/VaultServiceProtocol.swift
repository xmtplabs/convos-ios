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

public protocol VaultEventHandler: AnyObject, Sendable {
    func vaultDidImportInbox(inboxId: String, clientId: String) async
    func vaultDidImportKeyBundle(inboxIds: Set<String>, count: Int) async
    func vaultDidDeleteConversation(inboxId: String, clientId: String) async
}

public protocol VaultServiceProtocol: Sendable {
    func setEventHandler(_ handler: any VaultEventHandler) async
    func startVault(signingKey: SigningKey, options: ClientOptions) async throws
    func stopVault() async
    func pauseVault() async
    func resumeVault() async
    func unpairSelf() async throws
    func broadcastConversationDeleted(inboxId: String, clientId: String) async
    func createArchive(at path: URL, encryptionKey: Data) async throws
    @discardableResult
    func importArchive(from path: URL, encryptionKey: Data) async throws -> [VaultKeyEntry]
}

public extension Notification.Name {
    static let vaultDidReceiveKeyBundle: Notification.Name = .init("ConvosVaultDidReceiveKeyBundle")
    static let vaultPairingError: Notification.Name = .init("ConvosVaultPairingError")
    static let vaultDidReceivePin: Notification.Name = .init("ConvosVaultDidReceivePin")
    static let vaultDidEnterBackground: Notification.Name = .init("ConvosVaultDidEnterBackground")
    static let vaultWillEnterForeground: Notification.Name = .init("ConvosVaultWillEnterForeground")
}
