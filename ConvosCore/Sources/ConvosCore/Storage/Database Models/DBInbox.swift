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

    /// The local user's inbox id, or nil when no identity has been persisted
    /// yet (the window between a fresh install and the first session
    /// bootstrap). Convos persists a single `inbox` row per installation, so
    /// "the first row" is "the local inbox" - this centralizes that lookup so
    /// call sites don't each reach for `fetchAll(db).first`.
    static func currentInboxId(_ db: Database) throws -> String? {
        try DBInbox.fetchOne(db)?.inboxId
    }
}
