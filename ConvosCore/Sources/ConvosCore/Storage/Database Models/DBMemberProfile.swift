import ConvosAppData
import Foundation
import GRDB

enum DBMemberKind: String, Codable, Hashable {
    case agent
    case verifiedConvos = "agent:convos"
    case verifiedUserOAuth = "agent:user-oauth"

    var isAgent: Bool { true }

    var agentVerification: AgentVerification {
        switch self {
        case .agent:
            return .unverified
        case .verifiedConvos:
            return .verified(.convos)
        case .verifiedUserOAuth:
            return .verified(.userOAuth)
        }
    }

    static func from(agentVerification: AgentVerification) -> DBMemberKind {
        switch agentVerification {
        case .unverified:
            return .agent
        case .verified(.convos):
            return .verifiedConvos
        case .verified(.userOAuth):
            return .verifiedUserOAuth
        case .verified(.unknown):
            return .agent
        }
    }
}

struct DBMemberProfile: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "memberProfile"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let name: Column = Column(CodingKeys.name)
        static let avatar: Column = Column(CodingKeys.avatar)
        static let avatarSalt: Column = Column(CodingKeys.avatarSalt)
        static let avatarNonce: Column = Column(CodingKeys.avatarNonce)
        static let avatarKey: Column = Column(CodingKeys.avatarKey)
        static let avatarLastRenewed: Column = Column(CodingKeys.avatarLastRenewed)
        static let memberKind: Column = Column(CodingKeys.memberKind)
        static let metadata: Column = Column(CodingKeys.metadata)
    }

    let conversationId: String
    let inboxId: String
    let name: String?
    let avatar: String?
    let avatarSalt: Data?
    let avatarNonce: Data?
    let avatarKey: Data?
    let avatarLastRenewed: Date?
    let memberKind: DBMemberKind?
    let metadata: ProfileMetadata?

    var isAgent: Bool {
        memberKind?.isAgent ?? false
    }

    var agentVerification: AgentVerification {
        memberKind?.agentVerification ?? .unverified
    }

    init(
        conversationId: String,
        inboxId: String,
        name: String?,
        avatar: String?,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil,
        avatarKey: Data? = nil,
        avatarLastRenewed: Date? = nil,
        memberKind: DBMemberKind? = nil,
        metadata: ProfileMetadata? = nil
    ) {
        self.conversationId = conversationId
        self.inboxId = inboxId
        self.name = name
        self.avatar = avatar
        self.avatarSalt = avatarSalt
        self.avatarNonce = avatarNonce
        self.avatarKey = avatarKey
        self.avatarLastRenewed = avatarLastRenewed
        self.memberKind = memberKind
        self.metadata = metadata
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
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed, memberKind: memberKind, metadata: metadata
        )
    }

    func with(avatar: String?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed, memberKind: memberKind, metadata: metadata
        )
    }

    func with(avatar: String?, salt: Data?, nonce: Data?, key: Data?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: salt, avatarNonce: nonce, avatarKey: key,
            avatarLastRenewed: avatarLastRenewed, memberKind: memberKind, metadata: metadata
        )
    }

    func with(avatarLastRenewed: Date?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed, memberKind: memberKind, metadata: metadata
        )
    }

    func with(memberKind: DBMemberKind?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed, memberKind: memberKind, metadata: metadata
        )
    }

    func with(metadata: ProfileMetadata?) -> DBMemberProfile {
        .init(
            conversationId: conversationId, inboxId: inboxId, name: name, avatar: avatar,
            avatarSalt: avatarSalt, avatarNonce: avatarNonce, avatarKey: avatarKey,
            avatarLastRenewed: avatarLastRenewed, memberKind: memberKind, metadata: metadata
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
