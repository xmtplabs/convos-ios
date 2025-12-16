import Foundation
import GRDB

// MARK: - ConversationMemberProfileWithRole

struct DBConversationMemberProfileWithRole: Codable, FetchableRecord, Hashable {
    let memberProfile: DBMemberProfile
    let role: MemberRole
}

extension DBConversationMemberProfileWithRole {
    func hydrateConversationMember(currentInboxId: String) -> ConversationMember {
        .init(
            profile: memberProfile.hydrateProfile(),
            role: role,
            isCurrentUser: memberProfile.inboxId == currentInboxId
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
            .select([DBConversationMember.Columns.role])
            .including(required: DBConversationMember.memberProfile)
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
            .select([DBConversationMember.Columns.role])
            .including(required: DBConversationMember.memberProfile)
            .asRequest(of: DBConversationMemberProfileWithRole.self)
            .fetchAll(db)
    }
}
