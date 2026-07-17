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
    var invitedByInboxId: String?

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

    static let profile: HasOneAssociation<DBConversationMember, DBProfile> = hasOne(
        DBProfile.self,
        key: "profile",
        using: ForeignKey([Columns.inboxId], to: [DBProfile.Columns.inboxId])
    )

    // Joins the newest avatar per inbox (the `profileAvatarLatest` view), keyed by
    // inboxId only, so a person's latest avatar renders consistently across every
    // conversation rather than each conversation's own per-conversation slot.
    static let avatarSlot: HasOneAssociation<DBConversationMember, DBProfileAvatarLatest> = hasOne(
        DBProfileAvatarLatest.self,
        key: "avatarSlot",
        using: ForeignKey([Columns.inboxId], to: [DBProfileAvatarLatest.Columns.inboxId])
    )

    static let inviterProfileIdentity: BelongsToAssociation<DBConversationMember, DBProfile> = belongsTo(
        DBProfile.self,
        key: "inviterProfile",
        using: ForeignKey([Columns.invitedByInboxId], to: [DBProfile.Columns.inboxId])
    )

    // The current user is excluded from the canonical `profile` table (self
    // identity is authored locally in `myProfile`), so the joins above are nil
    // for the current user. These parallel joins resolve only for a local inbox
    // (`myProfile` holds only local rows), letting hydration fall back to the
    // self identity so the current user does not render as "Somebody" as a
    // member or an inviter. Only the identity columns are selected so the
    // `myProfile.imageData` blob is not dragged into every roster query.
    static let myProfileIdentity: HasOneAssociation<DBConversationMember, DBMyProfile> = hasOne(
        DBMyProfile.self,
        key: "myProfile",
        using: ForeignKey([Columns.inboxId], to: [DBMyProfile.Columns.inboxId])
    ).select(DBMyProfile.Columns.inboxId, DBMyProfile.Columns.name, DBMyProfile.Columns.metadata, DBMyProfile.Columns.updatedAt)

    static let inviterMyProfileIdentity: BelongsToAssociation<DBConversationMember, DBMyProfile> = belongsTo(
        DBMyProfile.self,
        key: "inviterMyProfile",
        using: ForeignKey([Columns.invitedByInboxId], to: [DBMyProfile.Columns.inboxId])
    ).select(DBMyProfile.Columns.inboxId, DBMyProfile.Columns.name, DBMyProfile.Columns.metadata, DBMyProfile.Columns.updatedAt)
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
