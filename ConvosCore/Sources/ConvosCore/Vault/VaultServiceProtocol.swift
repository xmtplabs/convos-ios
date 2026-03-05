import Foundation

public struct InboxKeyInfo: Sendable {
    public let inboxId: String
    public let clientId: String
    public let privateKeyData: Data
    public let databaseKey: Data

    public init(inboxId: String, clientId: String, privateKeyData: Data, databaseKey: Data) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.privateKeyData = privateKeyData
        self.databaseKey = databaseKey
    }
}

public protocol VaultServiceProtocol: Sendable {
    func unpairSelf() async throws
    func shareNewKey(_ keyInfo: InboxKeyInfo) async
}

public extension Notification.Name {
    static let inboxIdentityRegistered: Notification.Name = .init("ConvosInboxIdentityRegistered")
}

public enum InboxIdentityNotification {
    public static let keyInfoKey: String = "inboxKeyInfo"
}
