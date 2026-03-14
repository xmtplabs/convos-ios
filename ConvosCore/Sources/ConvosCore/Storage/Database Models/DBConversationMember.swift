import Foundation
import GRDB

// MARK: - DBConversationMember

struct DBConversationMember: Codable, FetchableRecord, PersistableRecord, Hashable {
    static var databaseTableName: String { "conversation_members" }

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let role: Column = Column(CodingKeys.role)
        static let consent: Column = Column(CodingKeys.consent)
        static let createdAt: Column = Column(CodingKeys.createdAt)
        static let invitedByInboxId: Column = Column(CodingKeys.invitedByInboxId)
    }

    let conversationId: String
    let inboxId: String
    let role: MemberRole
    let consent: Consent
    let createdAt: Date
    let invitedByInboxId: String?

    static let memberForeignKey: ForeignKey = ForeignKey([Columns.inboxId], to: [DBMember.Columns.inboxId])
    static let conversationForeignKey: ForeignKey = ForeignKey([Columns.conversationId], to: [DBConversation.Columns.id])

    // Foreign key to match invites created by this member for this conversation
    static let inviteForeignKey: ForeignKey = ForeignKey(
        [DBInvite.Columns.creatorInboxId, DBInvite.Columns.conversationId],
        to: [Columns.inboxId, Columns.conversationId]
    )

    static let invite: HasOneAssociation<DBConversationMember, DBInvite> = hasOne(
        DBInvite.self,
        key: "memberInvite",
        using: inviteForeignKey
    )

    static let conversation: BelongsToAssociation<DBConversationMember, DBConversation> = belongsTo(
        DBConversation.self,
        using: conversationForeignKey
    )

    static let member: BelongsToAssociation<DBConversationMember, DBMember> = belongsTo(
        DBMember.self,
        using: memberForeignKey
    )

    static let memberProfileForeignKey: ForeignKey = ForeignKey(
        [Columns.conversationId, Columns.inboxId],
        to: [DBMemberProfile.Columns.conversationId, DBMemberProfile.Columns.inboxId]
    )

    static let memberProfile: HasOneAssociation<DBConversationMember, DBMemberProfile> = hasOne(
        DBMemberProfile.self,
        using: memberProfileForeignKey
    )

    static let inviterProfileForeignKey: ForeignKey = ForeignKey(
        [Columns.invitedByInboxId, Columns.conversationId],
        to: [DBMemberProfile.Columns.inboxId, DBMemberProfile.Columns.conversationId]
    )

    static let inviterProfile: BelongsToAssociation<DBConversationMember, DBMemberProfile> = belongsTo(
        DBMemberProfile.self,
        key: "inviterProfile",
        using: inviterProfileForeignKey
    )
}

// MARK: - DBConversationMember Extensions

extension DBConversationMember {
    func with(role: MemberRole) -> Self {
        .init(
            conversationId: conversationId,
            inboxId: inboxId,
            role: role,
            consent: consent,
            createdAt: createdAt,
            invitedByInboxId: invitedByInboxId
        )
    }
}
