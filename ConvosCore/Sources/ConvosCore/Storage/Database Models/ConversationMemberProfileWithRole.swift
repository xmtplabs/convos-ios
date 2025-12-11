import Foundation
import GRDB

// MARK: - ConversationMemberProfileWithRole

struct ConversationMemberProfileWithRole: Codable, FetchableRecord, PersistableRecord, Hashable {
    let memberProfile: MemberProfile
    let role: MemberRole
}

extension ConversationMemberProfileWithRole {
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
    ) throws -> ConversationMemberProfileWithRole? {
        try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .filter(DBConversationMember.Columns.inboxId == inboxId)
            .select([DBConversationMember.Columns.role])
            .including(required: DBConversationMember.memberProfile)
            .asRequest(of: ConversationMemberProfileWithRole.self)
            .fetchOne(db)
    }

    static func fetchAll(
        _ db: Database,
        conversationId: String,
        inboxIds: [String]
    ) throws -> [ConversationMemberProfileWithRole] {
        try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .filter(inboxIds.contains(DBConversationMember.Columns.inboxId))
            .select([DBConversationMember.Columns.role])
            .including(required: DBConversationMember.memberProfile)
            .asRequest(of: ConversationMemberProfileWithRole.self)
            .fetchAll(db)
    }
}
