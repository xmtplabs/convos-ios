import Foundation
import GRDB

struct DBInbox: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName: String = "inbox"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let clientId: Column = Column(CodingKeys.clientId)
        static let createdAt: Column = Column(CodingKeys.createdAt)
    }

    var id: String { inboxId }
    let inboxId: String
    let clientId: String
    let createdAt: Date

    init(inboxId: String, clientId: String, createdAt: Date = Date()) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.createdAt = createdAt
    }

    static let member: HasOneAssociation<DBInbox, DBMember> = hasOne(
        DBMember.self,
        key: "inboxMember",
        using: ForeignKey(["inboxId"], to: ["inboxId"])
    )
}
