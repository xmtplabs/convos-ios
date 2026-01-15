import Foundation

extension DBConversationDetails {
    func hydrateConversation() -> Conversation {
        let lastMessage: MessagePreview? = conversationLastMessage?.hydrateMessagePreview(
            conversationKind: conversation.kind,
            currentInboxId: conversation.inboxId
        )
        let members = hydrateConversationMembers(currentInboxId: conversation.inboxId)
        let creator = conversationCreator.hydrateConversationMember(currentInboxId: conversation.inboxId)

        let otherMember: ConversationMember?
        if conversation.kind == .dm,
            let other = members.first(where: { !$0.isCurrentUser }) {
            otherMember = other
        } else {
            otherMember = nil
        }

        // we don't need messages for the conversations list
        let messages: [Message] = []

        let imageURL: URL?
        if let imageURLString = conversation.imageURLString {
            imageURL = URL(string: imageURLString)
        } else {
            imageURL = nil
        }

        return Conversation(
            id: conversation.id,
            clientConversationId: conversation.clientConversationId,
            inboxId: conversation.inboxId,
            clientId: conversation.clientId,
            creator: creator,
            createdAt: conversation.createdAt,
            consent: conversation.consent,
            kind: conversation.kind,
            name: conversation.name,
            description: conversation.description,
            members: members,
            otherMember: otherMember,
            messages: messages,
            isPinned: conversationLocalState.isPinned,
            isUnread: conversationLocalState.isUnread,
            isMuted: conversationLocalState.isMuted,
            pinnedOrder: conversationLocalState.pinnedOrder,
            lastMessage: lastMessage,
            imageURL: imageURL,
            isDraft: conversation.isDraft,
            invite: conversationInvite?.hydrateInvite(),
            expiresAt: conversation.expiresAt,
            debugInfo: conversation.debugInfo
        )
    }
}
