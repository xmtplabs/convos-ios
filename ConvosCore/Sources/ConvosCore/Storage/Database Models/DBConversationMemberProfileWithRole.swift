import Foundation
import GRDB

// MARK: - ConversationMemberProfileWithRole

struct DBConversationMemberProfileWithRole: Codable, FetchableRecord, Hashable {
    let memberProfile: DBMemberProfile
    let role: MemberRole
    let createdAt: Date
    let inviterProfile: DBMemberProfile?
}

extension DBConversationMemberProfileWithRole {
    func hydrateConversationMember(currentInboxId: String) -> ConversationMember {
        let profile = memberProfile.hydrateProfile()
        let isAgent = memberProfile.isAgent
        return .init(
            profile: profile,
            role: role,
            isCurrentUser: memberProfile.inboxId == currentInboxId,
            isAgent: isAgent,
            agentVerification: memberProfile.agentVerification,
            invitedBy: inviterProfile?.hydrateProfile(),
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
                DBConversationMember.Columns.role,
                DBConversationMember.Columns.createdAt,
            ])
            .including(required: DBConversationMember.memberProfile)
            .including(optional: DBConversationMember.inviterProfile)
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
                DBConversationMember.Columns.role,
                DBConversationMember.Columns.createdAt,
            ])
            .including(required: DBConversationMember.memberProfile)
            .including(optional: DBConversationMember.inviterProfile)
            .asRequest(of: DBConversationMemberProfileWithRole.self)
            .fetchAll(db)
    }
}
