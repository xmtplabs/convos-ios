import Foundation
import GRDB

// MARK: - DBConversation

public enum CommitLogForkStatus: String, Codable, Hashable, Sendable {
    case forked, notForked = "not_forked", unknown
}

public struct DBConversation: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    public static var databaseTableName: String = "conversation"

    public struct DebugInfo: Codable, Hashable, Sendable {
        public let epoch: UInt64
        public let maybeForked: Bool
        public let forkDetails: String
        public let localCommitLog: String
        public let remoteCommitLog: String
        public let commitLogForkStatus: CommitLogForkStatus
    }

    public enum Columns {
        static let id: Column = Column(CodingKeys.id)
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let clientId: Column = Column(CodingKeys.clientId)
        static let clientConversationId: Column = Column(CodingKeys.clientConversationId)
        static let inviteTag: Column = Column(CodingKeys.inviteTag)
        static let creatorId: Column = Column(CodingKeys.creatorId)
        static let kind: Column = Column(CodingKeys.kind)
        static let consent: Column = Column(CodingKeys.consent)
        static let createdAt: Column = Column(CodingKeys.createdAt)
        static let name: Column = Column(CodingKeys.name)
        static let description: Column = Column(CodingKeys.description)
        static let imageURLString: Column = Column(CodingKeys.imageURLString)
        static let expiresAt: Column = Column(CodingKeys.expiresAt)
        static let debugInfo: Column = Column(CodingKeys.debugInfo)
    }

    public let id: String
    public let inboxId: String
    public let clientId: String
    public let clientConversationId: String // used for conversation drafts
    public let inviteTag: String
    public let creatorId: String
    public let kind: ConversationKind
    public let consent: Consent
    public let createdAt: Date
    public let name: String?
    public let description: String?
    public let imageURLString: String?
    public let expiresAt: Date?
    public let debugInfo: DebugInfo

    static let creatorForeignKey: ForeignKey = ForeignKey(
        [Columns.creatorId, Columns.id],
        to: [DBConversationMember.Columns.inboxId, DBConversationMember.Columns.conversationId]
    )
    static let inboxMemberKey: ForeignKey = ForeignKey(
        [Columns.inboxId, Columns.id],
        to: [DBConversationMember.Columns.inboxId, DBConversationMember.Columns.conversationId]
    )
    static let localStateForeignKey: ForeignKey = ForeignKey([ConversationLocalState.Columns.conversationId], to: [Columns.id])
    static let inviteForeignKey: ForeignKey = ForeignKey([DBInvite.Columns.conversationId], to: [Columns.id])

    // The invite created by the current inbox member (the user viewing this conversation)
    static let invite: HasOneThroughAssociation<DBConversation, DBInvite> = hasOne(
        DBInvite.self,
        through: inboxMember,
        using: DBConversationMember.invite,
        key: "conversationInvite"
    )

    // The invite created by the conversation creator
    static let creatorInvite: HasOneThroughAssociation<DBConversation, DBInvite> = hasOne(
        DBInvite.self,
        through: creator,
        using: DBConversationMember.invite,
        key: "conversationCreatorInvite"
    )

    static let creator: BelongsToAssociation<DBConversation, DBConversationMember> = belongsTo(
        DBConversationMember.self,
        key: "conversationCreator",
        using: creatorForeignKey
    )

    // the member whose conversation this is
    static let inboxMember: BelongsToAssociation<DBConversation, DBConversationMember> = belongsTo(
        DBConversationMember.self,
        key: "conversationInboxMember",
        using: inboxMemberKey
    )

    static let creatorProfile: HasOneThroughAssociation<DBConversation, MemberProfile> = hasOne(
        MemberProfile.self,
        through: creator,
        using: DBConversationMember.memberProfile,
        key: "conversationCreatorProfile"
    )

    static let _members: HasManyAssociation<DBConversation, DBConversationMember> = hasMany(
        DBConversationMember.self,
        key: "conversationMembers"
    ).order(DBConversationMember.Columns.createdAt.asc)

    static let members: HasManyThroughAssociation<DBConversation, Member> = hasMany(
        Member.self,
        through: _members,
        using: DBConversationMember.member,
        key: "conversationMembers"
    )

    static let memberProfiles: HasManyThroughAssociation<DBConversation, MemberProfile> = hasMany(
        MemberProfile.self,
        through: _members,
        using: DBConversationMember.memberProfile,
        key: "conversationMemberProfiles"
    )

    static let messages: HasManyAssociation<DBConversation, DBMessage> = hasMany(
        DBMessage.self,
        key: "conversationMessages",
        using: ForeignKey([Columns.id], to: [DBMessage.Columns.conversationId])
    ).order(DBMessage.Columns.dateNs.desc)

    static let lastMessageRequest: QueryInterfaceRequest<DBMessage> = DBMessage
        .filter(DBMessage.Columns.contentType != MessageContentType.update.rawValue)
        .annotated { max($0.dateNs) }
        .group(\.conversationId)

    static let lastMessageCTE: CommonTableExpression<DBMessage> = CommonTableExpression<DBMessage>(
        named: "conversationLastMessage",
        request: lastMessageRequest
    )

    static let localState: HasOneAssociation<DBConversation, ConversationLocalState> = hasOne(
        ConversationLocalState.self,
        key: "conversationLocalState",
        using: localStateForeignKey
    )
}

// MARK: - DBConversation Extensions

extension DBConversation.DebugInfo {
    static var empty: Self {
        .init(
            epoch: 0,
            maybeForked: false,
            forkDetails: "",
            localCommitLog: "",
            remoteCommitLog: "",
            commitLogForkStatus: .unknown
        )
    }
}

extension DBConversation {
    private static var draftPrefix: String { "draft-" }

    static func generateDraftConversationId() -> String {
        "\(draftPrefix)\(UUID().uuidString)"
    }

    static func isDraft(id: String) -> Bool {
        id.hasPrefix(draftPrefix)
    }

    var isDraft: Bool {
        Self.isDraft(id: id) && Self.isDraft(id: clientConversationId)
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    func with(id: String) -> Self {
        .init(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            expiresAt: expiresAt,
            debugInfo: debugInfo
        )
    }

    func with(clientConversationId: String) -> Self {
        .init(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            expiresAt: expiresAt,
            debugInfo: debugInfo
        )
    }

    func with(creatorId: String) -> Self {
        .init(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            expiresAt: expiresAt,
            debugInfo: debugInfo
        )
    }

    func with(kind: ConversationKind) -> Self {
        .init(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            expiresAt: expiresAt,
            debugInfo: debugInfo
        )
    }

    func with(consent: Consent) -> Self {
        .init(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            expiresAt: expiresAt,
            debugInfo: debugInfo
        )
    }

    // MARK: - Group Conversation Properties

    func with(name: String?) -> Self {
        .init(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            expiresAt: expiresAt,
            debugInfo: debugInfo
        )
    }

    func with(description: String?) -> Self {
        .init(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            expiresAt: expiresAt,
            debugInfo: debugInfo
        )
    }

    func with(expiresAt: Date) -> Self {
        .init(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            expiresAt: expiresAt,
            debugInfo: debugInfo
        )
    }

    func with(imageURLString: String?) -> Self {
        .init(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            expiresAt: expiresAt,
            debugInfo: debugInfo
        )
    }

    func postLeftConversationNotification() {
        NotificationCenter.default.post(
            name: .leftConversationNotification,
            object: nil,
            userInfo: [
                "clientId": clientId,
                "inboxId": inboxId,
                "conversationId": id
            ]
        )
    }
}
