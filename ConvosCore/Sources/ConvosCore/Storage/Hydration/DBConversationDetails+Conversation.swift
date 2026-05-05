import Foundation

extension DBConversationDetails {
    func hydrateConversation(currentInboxId: String) -> Conversation {
        let lastMessage: MessagePreview? = conversationLastMessageWithSource?.hydrateMessagePreview(
            conversationKind: conversation.kind,
            currentInboxId: currentInboxId,
            members: conversationMembers
        )
        let members = hydrateConversationMembers(currentInboxId: currentInboxId)
        let creator = conversationCreator.hydrateConversationMember(currentInboxId: currentInboxId)

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

        let assistantJoinStatus: AssistantJoinStatus?
        if let joinRequest = conversationAssistantJoinRequest,
           let status = AssistantJoinStatus(rawValue: joinRequest.status),
           !members.contains(where: { $0.isAgent }) {
            let age = Date().timeIntervalSince(joinRequest.date)
            assistantJoinStatus = age <= status.displayDuration ? status : nil
        } else {
            assistantJoinStatus = nil
        }

        let invite = conversationInvites
            .first { $0.creatorInboxId == currentInboxId }?
            .hydrateInvite()

        return Conversation(
            id: conversation.id,
            clientConversationId: conversation.clientConversationId,
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
            isActive: conversationLocalState.isActive,
            lastMessage: lastMessage,
            imageURL: imageURL,
            imageSalt: conversation.imageSalt,
            imageNonce: conversation.imageNonce,
            imageEncryptionKey: conversation.imageEncryptionKey,
            conversationEmoji: conversation.conversationEmoji,
            includeInfoInPublicPreview: conversation.includeInfoInPublicPreview,
            isDraft: conversation.isDraft,
            invite: invite,
            expiresAt: conversation.expiresAt,
            debugInfo: conversation.debugInfo,
            isLocked: conversation.isLocked,
            assistantJoinStatus: assistantJoinStatus,
            hasHadVerifiedAssistant: conversation.hasHadVerifiedAssistant
        )
    }
}
