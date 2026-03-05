import Foundation
import GRDB

struct DBInbox: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName: String = "inbox"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let clientId: Column = Column(CodingKeys.clientId)
        static let createdAt: Column = Column(CodingKeys.createdAt)
        static let isVault: Column = Column(CodingKeys.isVault)
    }

    var id: String { inboxId }
    let inboxId: String
    let clientId: String
    let createdAt: Date
    let isVault: Bool

    init(inboxId: String, clientId: String, createdAt: Date = Date(), isVault: Bool = false) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.createdAt = createdAt
        self.isVault = isVault
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
