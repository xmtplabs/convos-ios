import Foundation
import GRDB

// MARK: - DBConversationDetails

struct DBConversationDetails: Codable, FetchableRecord, PersistableRecord, Hashable {
    let conversation: DBConversation
    let conversationCreator: DBConversationMemberProfileWithRole
    let conversationMembers: [DBConversationMemberProfileWithRole]
    let conversationLastMessageWithSource: DBLastMessageWithSource?
    let conversationLocalState: ConversationLocalState
    let conversationInvite: DBInvite?
    let conversationAssistantJoinRequest: DBAssistantJoinRequest?
}

extension DBConversationDetails {
    func hydrateConversationMembers(currentInboxId: String) -> [ConversationMember] {
        return conversationMembers.compactMap { member in
            member.hydrateConversationMember(currentInboxId: currentInboxId)
        }
    }
}
