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
    let myProfile: DBMyProfile?
    let inviterMyProfile: DBMyProfile?
}

extension DBConversationMemberProfileWithRole {
    var isAgent: Bool {
        profile?.memberKind?.isAgent ?? false
    }

    var agentVerification: AgentVerification {
        profile?.memberKind?.agentVerification ?? .unverified
    }

    /// Effective display name: the canonical `profile` name, falling back to the
    /// locally-authored `myProfile` for the current user, who is excluded from
    /// `profile`. Reads that project the name directly (rather than through
    /// `hydratedProfile()`) must use this so self does not render as "Somebody".
    var resolvedName: String? {
        profile?.name ?? myProfile?.name
    }

    func hydratedProfile() -> Profile {
        if let profile {
            return Profile.from(profile: profile, avatar: avatarSlot?.asProfileAvatar, inboxId: inboxId, conversationId: conversationId)
        }
        // The current user is excluded from the canonical `profile` table, so
        // fall back to the locally-authored self identity for this member.
        return Profile.from(myProfile: myProfile, avatar: avatarSlot?.asProfileAvatar, inboxId: inboxId, conversationId: conversationId)
    }

    func hydrateConversationMember(currentInboxId: String) -> ConversationMember {
        let invitedByProfile: Profile?
        if let inviterProfile {
            invitedByProfile = Profile.from(profile: inviterProfile, avatar: nil, inboxId: inviterProfile.inboxId, conversationId: conversationId)
        } else if let inviterMyProfile {
            invitedByProfile = Profile.from(myProfile: inviterMyProfile, avatar: nil, inboxId: inviterMyProfile.inboxId, conversationId: conversationId)
        } else {
            invitedByProfile = nil
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
            .including(optional: DBConversationMember.myProfileIdentity)
            .including(optional: DBConversationMember.inviterMyProfileIdentity)
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
            .including(optional: DBConversationMember.myProfileIdentity)
            .including(optional: DBConversationMember.inviterMyProfileIdentity)
            .asRequest(of: DBConversationMemberProfileWithRole.self)
            .fetchAll(db)
    }
}
