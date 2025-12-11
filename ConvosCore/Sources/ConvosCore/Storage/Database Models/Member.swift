import Foundation
import GRDB

struct Member: Codable, FetchableRecord, PersistableRecord, Hashable {
    static var databaseTableName: String = "member"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
    }

    let inboxId: String

    static let profilesForeignKey: ForeignKey = ForeignKey([Columns.inboxId], to: [MemberProfile.Columns.inboxId])

    static let profiles: HasManyAssociation<Member, MemberProfile> = hasMany(
        MemberProfile.self,
        using: profilesForeignKey
    )
}
