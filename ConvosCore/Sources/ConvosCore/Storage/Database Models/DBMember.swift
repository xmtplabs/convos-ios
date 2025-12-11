import Foundation
import GRDB

struct DBMember: Codable, FetchableRecord, PersistableRecord, Hashable {
    static var databaseTableName: String = "member"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
    }

    let inboxId: String

    static let profilesForeignKey: ForeignKey = ForeignKey([Columns.inboxId], to: [DBMemberProfile.Columns.inboxId])

    static let profiles: HasManyAssociation<DBMember, DBMemberProfile> = hasMany(
        DBMemberProfile.self,
        using: profilesForeignKey
    )
}
