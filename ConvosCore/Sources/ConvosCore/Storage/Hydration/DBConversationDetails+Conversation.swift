import Foundation

extension DBConversationDetails {
    func hydrateConversation() -> Conversation {
        let lastMessage: MessagePreview? = conversationLastMessage?.hydrateMessagePreview(
            conversationKind: conversation.kind
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

        let imageURL = conversation.imageURLString.flatMap { URL(string: $0) }

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
            lastMessage: lastMessage,
            imageURL: imageURL,
            isDraft: conversation.isDraft,
            invite: conversationInvite?.hydrateInvite(),
            expiresAt: conversation.expiresAt,
            debugInfo: conversation.debugInfo
        )
    }
}
