import Foundation
import GRDB

// MARK: - DBLastMessageWithSource

struct DBLastMessageWithSource: Codable, FetchableRecord, Hashable {
    let id: String
    let clientMessageId: String
    let conversationId: String
    let senderId: String
    let dateNs: Int64
    let date: Date
    let status: MessageStatus
    let messageType: DBMessageType
    let contentType: MessageContentType
    let text: String?
    let emoji: String?
    let invite: MessageInvite?
    let linkPreview: LinkPreview?
    let sourceMessageId: String?
    let attachmentUrls: [String]
    let sourceMessageText: String?
}

// MARK: - DBConversation

struct DBConversation: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName: String = "conversation"

    enum Columns {
        static let id: Column = Column(CodingKeys.id)
        static let clientConversationId: Column = Column(CodingKeys.clientConversationId)
        static let inviteTag: Column = Column(CodingKeys.inviteTag)
        static let creatorId: Column = Column(CodingKeys.creatorId)
        static let kind: Column = Column(CodingKeys.kind)
        static let consent: Column = Column(CodingKeys.consent)
        static let createdAt: Column = Column(CodingKeys.createdAt)
        static let name: Column = Column(CodingKeys.name)
        static let description: Column = Column(CodingKeys.description)
        static let imageURLString: Column = Column(CodingKeys.imageURLString)
        static let publicImageURLString: Column = Column(CodingKeys.publicImageURLString)
        static let includeInfoInPublicPreview: Column = Column(CodingKeys.includeInfoInPublicPreview)
        static let expiresAt: Column = Column(CodingKeys.expiresAt)
        static let debugInfo: Column = Column(CodingKeys.debugInfo)
        static let isLocked: Column = Column(CodingKeys.isLocked)
        static let imageSalt: Column = Column(CodingKeys.imageSalt)
        static let imageNonce: Column = Column(CodingKeys.imageNonce)
        static let imageEncryptionKey: Column = Column(CodingKeys.imageEncryptionKey)
        static let conversationEmoji: Column = Column(CodingKeys.conversationEmoji)
        static let imageLastRenewed: Column = Column(CodingKeys.imageLastRenewed)
        static let isUnused: Column = Column(CodingKeys.isUnused)
        static let hasHadVerifiedAssistant: Column = Column(CodingKeys.hasHadVerifiedAssistant)
    }

    let id: String
    let clientConversationId: String // used for conversation drafts
    let inviteTag: String
    let creatorId: String
    let kind: ConversationKind
    let consent: Consent
    let createdAt: Date
    let name: String?
    let description: String?
    let imageURLString: String?
    let publicImageURLString: String?
    let includeInfoInPublicPreview: Bool
    let expiresAt: Date?
    let debugInfo: ConversationDebugInfo
    let isLocked: Bool
    let imageSalt: Data?
    let imageNonce: Data?
    let imageEncryptionKey: Data?
    let conversationEmoji: String?
    let imageLastRenewed: Date?
    let isUnused: Bool
    let hasHadVerifiedAssistant: Bool

    static let creatorForeignKey: ForeignKey = ForeignKey(
        [Columns.creatorId, Columns.id],
        to: [DBConversationMember.Columns.inboxId, DBConversationMember.Columns.conversationId]
    )
    static let localStateForeignKey: ForeignKey = ForeignKey([ConversationLocalState.Columns.conversationId], to: [Columns.id])
    static let inviteForeignKey: ForeignKey = ForeignKey([DBInvite.Columns.conversationId], to: [Columns.id])

    // All invites associated with this conversation. The pre-C11 model had a
    // singular `invite` association resolved via a foreign key keyed on
    // `(inboxId, id)` — that key required `conversation.inboxId`, which is
    // gone in single-inbox mode. Callers that want "the current user's
    // invite" filter by `creatorInboxId == singletonInboxId` at hydration
    // time (see `DBConversationDetails+Conversation.hydrateConversation`).
    static let invites: HasManyAssociation<DBConversation, DBInvite> = hasMany(
        DBInvite.self,
        key: "conversationInvites",
        using: ForeignKey([DBInvite.Columns.conversationId], to: [Columns.id])
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

    static let creatorProfile: HasOneThroughAssociation<DBConversation, DBMemberProfile> = hasOne(
        DBMemberProfile.self,
        through: creator,
        using: DBConversationMember.memberProfile,
        key: "conversationCreatorProfile"
    )

    static let _members: HasManyAssociation<DBConversation, DBConversationMember> = hasMany(
        DBConversationMember.self,
        key: "conversationMembers"
    ).order(DBConversationMember.Columns.createdAt.asc)

    static let members: HasManyThroughAssociation<DBConversation, DBMember> = hasMany(
        DBMember.self,
        through: _members,
        using: DBConversationMember.member,
        key: "conversationMembers"
    )

    static let memberProfiles: HasManyThroughAssociation<DBConversation, DBMemberProfile> = hasMany(
        DBMemberProfile.self,
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
        .filter(DBMessage.Columns.contentType != MessageContentType.assistantJoinRequest.rawValue)
        .annotated { max($0.dateNs) }
        .group(\.conversationId)

    nonisolated(unsafe) static let lastMessageCTE: CommonTableExpression<DBMessage> = CommonTableExpression<DBMessage>(
        named: "conversationLastMessage",
        request: lastMessageRequest
    )

    nonisolated(unsafe) static let lastMessageWithSourceCTE: CommonTableExpression<DBLastMessageWithSource> =
        CommonTableExpression<DBLastMessageWithSource>(
            named: "conversationLastMessageWithSource",
            sql: """
                SELECT
                    m.id, m.clientMessageId, m.conversationId, m.senderId,
                    m.dateNs, m.date, m.status, m.messageType, m.contentType,
                    m.text, m.emoji, m.invite, m.linkPreview, m.sourceMessageId, m.attachmentUrls,
                    src.text as sourceMessageText
                FROM message m
                LEFT JOIN message src ON m.sourceMessageId = src.id
                WHERE m.contentType NOT IN (?, ?)
                AND m.dateNs = (
                    SELECT MAX(m2.dateNs)
                    FROM message m2
                    WHERE m2.conversationId = m.conversationId
                    AND m2.contentType NOT IN (?, ?)
                )
                """,
            arguments: [
                MessageContentType.update.rawValue,
                MessageContentType.assistantJoinRequest.rawValue,
                MessageContentType.update.rawValue,
                MessageContentType.assistantJoinRequest.rawValue,
            ]
        )

    nonisolated(unsafe) static let latestAssistantJoinRequestCTE: CommonTableExpression<DBAssistantJoinRequest> =
        CommonTableExpression<DBAssistantJoinRequest>(
            named: "conversationAssistantJoinRequest",
            sql: """
                SELECT m.conversationId, m.text AS status, m.date
                FROM message m
                WHERE m.contentType = ?
                AND m.dateNs = (
                    SELECT MAX(m2.dateNs)
                    FROM message m2
                    WHERE m2.conversationId = m.conversationId
                    AND m2.contentType = ?
                )
                """,
            arguments: [
                MessageContentType.assistantJoinRequest.rawValue,
                MessageContentType.assistantJoinRequest.rawValue,
            ]
        )

    static let localState: HasOneAssociation<DBConversation, ConversationLocalState> = hasOne(
        ConversationLocalState.self,
        key: "conversationLocalState",
        using: localStateForeignKey
    )
}

// MARK: - DBConversation Extensions

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
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(clientConversationId: String) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(creatorId: String) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(kind: ConversationKind) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(consent: Consent) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    // MARK: - Group Conversation Properties

    func with(name: String?) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(description: String?) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(createdAt: Date) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(expiresAt: Date) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(imageURLString: String?) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(imageURLString: String?, imageSalt: Data?, imageNonce: Data?, imageEncryptionKey: Data?) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(publicImageURLString: String?) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(includeInfoInPublicPreview: Bool) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(isLocked: Bool) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(isUnused: Bool) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(inviteTag: String) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(imageLastRenewed: Date?) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func with(hasHadVerifiedAssistant: Bool) -> Self {
        .init(
            id: id,
            clientConversationId: clientConversationId,
            inviteTag: inviteTag,
            creatorId: creatorId,
            kind: kind,
            consent: consent,
            createdAt: createdAt,
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: publicImageURLString,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: isUnused,
            hasHadVerifiedAssistant: hasHadVerifiedAssistant
        )
    }

    func postLeftConversationNotification() {
        NotificationCenter.default.post(
            name: .leftConversationNotification,
            object: nil,
            userInfo: ["conversationId": id]
        )
    }
}
