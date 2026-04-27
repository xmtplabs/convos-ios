import Foundation
import GRDB

// MARK: - DBConversationDetails

struct DBConversationDetails: Codable, FetchableRecord, PersistableRecord, Hashable {
    let conversation: DBConversation
    let conversationCreator: DBConversationMemberProfileWithRole
    let conversationMembers: [DBConversationMemberProfileWithRole]
    let conversationLastMessageWithSource: DBLastMessageWithSource?
    let conversationLocalState: ConversationLocalState
    /// Invites associated with this conversation. Hydration picks the
    /// current user's invite by filtering on `creatorInboxId`. Decoded as
    /// empty when the caller's query doesn't include
    /// `DBConversation.invites` — see the custom `init(from:)` below.
    let conversationInvites: [DBInvite]
    let conversationAssistantJoinRequest: DBAssistantJoinRequest?

    init(
        conversation: DBConversation,
        conversationCreator: DBConversationMemberProfileWithRole,
        conversationMembers: [DBConversationMemberProfileWithRole],
        conversationLastMessageWithSource: DBLastMessageWithSource?,
        conversationLocalState: ConversationLocalState,
        conversationInvites: [DBInvite] = [],
        conversationAssistantJoinRequest: DBAssistantJoinRequest?
    ) {
        self.conversation = conversation
        self.conversationCreator = conversationCreator
        self.conversationMembers = conversationMembers
        self.conversationLastMessageWithSource = conversationLastMessageWithSource
        self.conversationLocalState = conversationLocalState
        self.conversationInvites = conversationInvites
        self.conversationAssistantJoinRequest = conversationAssistantJoinRequest
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.conversation = try container.decode(DBConversation.self, forKey: .conversation)
        self.conversationCreator = try container.decode(DBConversationMemberProfileWithRole.self, forKey: .conversationCreator)
        self.conversationMembers = try container.decode([DBConversationMemberProfileWithRole].self, forKey: .conversationMembers)
        self.conversationLastMessageWithSource = try container.decodeIfPresent(DBLastMessageWithSource.self, forKey: .conversationLastMessageWithSource)
        self.conversationLocalState = try container.decode(ConversationLocalState.self, forKey: .conversationLocalState)
        self.conversationInvites = try container.decodeIfPresent([DBInvite].self, forKey: .conversationInvites) ?? []
        self.conversationAssistantJoinRequest = try container.decodeIfPresent(DBAssistantJoinRequest.self, forKey: .conversationAssistantJoinRequest)
    }
}

extension DBConversationDetails {
    func hydrateConversationMembers(currentInboxId: String) -> [ConversationMember] {
        return conversationMembers.compactMap { member in
            member.hydrateConversationMember(currentInboxId: currentInboxId)
        }
    }
}
