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
    func shareNewKey(_ keyInfo: InboxKeyInfo) async
}

public extension Notification.Name {
    static let inboxIdentityRegistered: Notification.Name = .init("ConvosInboxIdentityRegistered")
}

public enum InboxIdentityNotification {
    public static let keyInfoKey: String = "inboxKeyInfo"
}
