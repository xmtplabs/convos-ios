import Foundation
import GRDB

struct DBMemberProfile: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "memberProfile"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let name: Column = Column(CodingKeys.name)
        static let avatar: Column = Column(CodingKeys.avatar)
        static let avatarSalt: Column = Column(CodingKeys.avatarSalt)
        static let avatarNonce: Column = Column(CodingKeys.avatarNonce)
    }

    let conversationId: String
    let inboxId: String
    let name: String?
    let avatar: String?
    let avatarSalt: Data?
    let avatarNonce: Data?

    init(
        conversationId: String,
        inboxId: String,
        name: String?,
        avatar: String?,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil
    ) {
        self.conversationId = conversationId
        self.inboxId = inboxId
        self.name = name
        self.avatar = avatar
        self.avatarSalt = avatarSalt
        self.avatarNonce = avatarNonce
    }

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
            avatar: avatar,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce
        )
    }

    func with(avatar: String?) -> DBMemberProfile {
        .init(
            conversationId: conversationId,
            inboxId: inboxId,
            name: name,
            avatar: avatar,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce
        )
    }

    func with(avatar: String?, salt: Data?, nonce: Data?) -> DBMemberProfile {
        .init(
            conversationId: conversationId,
            inboxId: inboxId,
            name: name,
            avatar: avatar,
            avatarSalt: salt,
            avatarNonce: nonce
        )
    }

    var hasValidEncryptedAvatar: Bool {
        guard let salt = avatarSalt,
              let nonce = avatarNonce,
              avatar != nil else {
            return false
        }
        return salt.count == 32 && nonce.count == 12
    }

    var encryptedImageRef: EncryptedImageRef? {
        guard hasValidEncryptedAvatar,
              let url = avatar,
              let salt = avatarSalt,
              let nonce = avatarNonce else {
            return nil
        }
        var ref = EncryptedImageRef()
        ref.url = url
        ref.salt = salt
        ref.nonce = nonce
        return ref
    }
}
