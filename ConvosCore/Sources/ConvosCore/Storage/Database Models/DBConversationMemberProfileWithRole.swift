import Foundation
import GRDB

// MARK: - ConversationMemberProfileWithRole

struct DBConversationMemberProfileWithRole: Codable, FetchableRecord, Hashable {
    let conversationId: String
    let inboxId: String
    let role: MemberRole
    let createdAt: Date
    let profile: DBProfile?
    let avatarSlot: DBProfileAvatarLatest?
    let inviterProfile: DBProfile?
}

extension DBConversationMemberProfileWithRole {
    var isAgent: Bool {
        profile?.memberKind?.isAgent ?? false
    }

    var agentVerification: AgentVerification {
        profile?.memberKind?.agentVerification ?? .unverified
    }

    func hydratedProfile() -> Profile {
        Profile.from(profile: profile, avatar: avatarSlot?.asProfileAvatar, inboxId: inboxId, conversationId: conversationId)
    }

    func hydrateConversationMember(currentInboxId: String) -> ConversationMember {
        let invitedByProfile = inviterProfile.map {
            Profile.from(profile: $0, avatar: nil, inboxId: $0.inboxId, conversationId: conversationId)
        }
        return .init(
            profile: hydratedProfile(),
            role: role,
            isCurrentUser: inboxId == currentInboxId,
            isAgent: isAgent,
            agentVerification: agentVerification,
            invitedBy: invitedByProfile,
            joinedAt: createdAt
        )
    }

    static func fetchOne(
        _ db: Database,
        conversationId: String,
        inboxId: String
    ) throws -> DBConversationMemberProfileWithRole? {
        try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .filter(DBConversationMember.Columns.inboxId == inboxId)
            .select([
                DBConversationMember.Columns.conversationId,
                DBConversationMember.Columns.inboxId,
                DBConversationMember.Columns.role,
                DBConversationMember.Columns.createdAt,
            ])
            .including(optional: DBConversationMember.profile)
            .including(optional: DBConversationMember.avatarSlot)
            .including(optional: DBConversationMember.inviterProfileIdentity)
            .asRequest(of: DBConversationMemberProfileWithRole.self)
            .fetchOne(db)
    }

    static func fetchAll(
        _ db: Database,
        conversationId: String,
        inboxIds: [String]
    ) throws -> [DBConversationMemberProfileWithRole] {
        try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .filter(inboxIds.contains(DBConversationMember.Columns.inboxId))
            .select([
                DBConversationMember.Columns.conversationId,
                DBConversationMember.Columns.inboxId,
                DBConversationMember.Columns.role,
                DBConversationMember.Columns.createdAt,
            ])
            .including(optional: DBConversationMember.profile)
            .including(optional: DBConversationMember.avatarSlot)
            .including(optional: DBConversationMember.inviterProfileIdentity)
            .asRequest(of: DBConversationMemberProfileWithRole.self)
            .fetchAll(db)
    }
}
