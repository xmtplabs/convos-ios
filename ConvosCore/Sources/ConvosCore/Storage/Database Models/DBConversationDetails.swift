import Foundation
import GRDB

// MARK: - DBConversationDetails

struct DBConversationDetails: Codable, FetchableRecord, PersistableRecord, Hashable {
    let conversation: DBConversation
    let conversationCreator: DBConversationMemberProfileWithRole
    let conversationMembers: [DBConversationMemberProfileWithRole]
    let conversationLastMessageWithSource: DBLastMessageWithSource?
    let conversationLocalState: ConversationLocalState
    // Invites on this conversation. Pre-C11 this was a single-valued
    // `conversationInvite: DBInvite?` resolved via the now-removed
    // `(inboxId, id) → conversation_members(inboxId, conversationId)`
    // foreign key. That key depended on `conversation.inboxId`, which is
    // gone in single-inbox mode. We now fetch all invites for the row and
    // pick the current user's in hydration via the passed-in singleton
    // inboxId. Kept optional (empty default) so decoders that don't include
    // the `DBConversation.invites` association — e.g. the lightweight
    // benchmark path — don't trip `keyNotFound`.
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
