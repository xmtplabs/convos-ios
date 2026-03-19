import Foundation
import GRDB

public enum VaultSyncState: String, Codable, DatabaseValueConvertible, Sendable {
    case none
    case pending
    case synced
    case failed
}

struct DBInbox: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName: String = "inbox"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let clientId: Column = Column(CodingKeys.clientId)
        static let createdAt: Column = Column(CodingKeys.createdAt)
        static let isVault: Column = Column(CodingKeys.isVault)
        static let sharedToVault: Column = Column(CodingKeys.sharedToVault)
        static let vaultSyncState: Column = Column(CodingKeys.vaultSyncState)
        static let vaultSyncAttempts: Column = Column(CodingKeys.vaultSyncAttempts)
    }

    var id: String { inboxId }
    let inboxId: String
    let clientId: String
    let createdAt: Date
    let isVault: Bool
    var sharedToVault: Bool
    var vaultSyncState: VaultSyncState
    var vaultSyncAttempts: Int

    init(
        inboxId: String,
        clientId: String,
        createdAt: Date = Date(),
        isVault: Bool = false,
        sharedToVault: Bool = false,
        vaultSyncState: VaultSyncState = .none,
        vaultSyncAttempts: Int = 0
    ) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.createdAt = createdAt
        self.isVault = isVault
        self.sharedToVault = sharedToVault
        self.vaultSyncState = vaultSyncState
        self.vaultSyncAttempts = vaultSyncAttempts
    }

    static let conversations: HasManyAssociation<DBInbox, DBConversation> = hasMany(
        DBConversation.self,
        key: "conversations",
        using: ForeignKey([Columns.inboxId], to: [DBConversation.Columns.inboxId])
    )

    static let member: HasOneAssociation<DBInbox, DBMember> = hasOne(
        DBMember.self,
        key: "inboxMember",
        using: ForeignKey(["inboxId"], to: ["inboxId"])
    )
}
