import Foundation
import GRDB

struct DBMemberProfile: Codable, FetchableRecord, PersistableRecord, Hashable {
    static var databaseTableName: String = "memberProfile"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let name: Column = Column(CodingKeys.name)
        static let avatar: Column = Column(CodingKeys.avatar)
    }

    let conversationId: String
    let inboxId: String
    let name: String?
    let avatar: String?

    static let memberForeignKey: ForeignKey = ForeignKey([Columns.inboxId], to: [DBMember.Columns.inboxId])
    static let conversationForeignKey: ForeignKey = ForeignKey([Columns.conversationId], to: [DBConversation.Columns.id])

    static let member: BelongsToAssociation<DBMemberProfile, DBMember> = belongsTo(
        DBMember.self,
        using: memberForeignKey
    )

    static let conversation: BelongsToAssociation<DBMemberProfile, DBConversation> = belongsTo(
        DBConversation.self,
        using: conversationForeignKey
    )
}

extension DBMemberProfile {
    static func fetchOne(
        _ db: Database,
        conversationId: String,
        inboxId: String
    ) throws -> DBMemberProfile? {
        try fetchOne(
            db,
            key: [
                Columns.conversationId.name: conversationId,
                Columns.inboxId.name: inboxId
            ]
        )
    }

    static func fetchAll(
        _ db: Database,
        conversationId: String,
        inboxIds: [String]
    ) throws -> [DBMemberProfile] {
        let keys = inboxIds.map {
            [
                Columns.conversationId.name: conversationId,
                Columns.inboxId.name: $0
            ]
        }
        return try fetchAll(db, keys: keys)
    }

    func with(name: String?) -> DBMemberProfile {
        .init(
            conversationId: conversationId,
            inboxId: inboxId,
            name: name,
            avatar: avatar
        )
    }

    func with(avatar: String?) -> DBMemberProfile {
        .init(
            conversationId: conversationId,
            inboxId: inboxId,
            name: name,
            avatar: avatar
        )
    }
}
