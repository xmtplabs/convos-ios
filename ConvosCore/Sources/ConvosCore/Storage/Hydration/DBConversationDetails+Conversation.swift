import Foundation

extension DBConversationDetails {
    /// `contactNameResolver` supplies the fallback contact name for the
    /// last-message preview only (the conversation-list subtitle), so a member
    /// with an empty per-conversation name shows the contact name instead of
    /// "Somebody". Defaults to a no-op.
    func hydrateConversation(
        currentInboxId: String,
        contactNameResolver: (String) -> String? = { _ in nil }
    ) -> Conversation {
        let lastMessage: MessagePreview? = conversationLastMessageWithSource?.hydrateMessagePreview(
            conversationKind: conversation.kind,
            currentInboxId: currentInboxId,
            members: conversationMembers,
            contactNameResolver: contactNameResolver
        )
        let members = hydrateConversationMembers(currentInboxId: currentInboxId)
        let creator = hydrateCreator(currentInboxId: currentInboxId)

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

        let agentJoinStatus: AgentJoinStatus?
        if let joinRequest = conversationAgentJoinRequest,
           let status = AgentJoinStatus(rawValue: joinRequest.status),
           !members.contains(where: { $0.isAgent }) {
            let age = Date().timeIntervalSince(joinRequest.date)
            agentJoinStatus = age <= status.displayDuration ? status : nil
        } else {
            agentJoinStatus = nil
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
            hidesInviteCard: conversationLocalState.hidesInviteCard,
            leftHostedInviteSession: conversationLocalState.leftHostedInviteSession,
            wasRemoved: conversationLocalState.wasRemoved,
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
            agentJoinStatus: agentJoinStatus,
            hasHadVerifiedAgent: conversation.hasHadVerifiedAgent,
            wasCreatedFromAgentBuilder: conversationAgentBuilderSummary != nil
        )
    }

    /// The creator's `conversation_members` row is deleted when they leave the
    /// group, so `conversationCreator` can be nil. Consumers only rely on the
    /// creator's identity (`isCurrentUser` checks), so fall back to a minimal
    /// member built from the stored `creatorId` -- the same shape
    /// `MessagesRepository.fetchLightweightConversation` synthesizes for a
    /// missing creator, so both hydration paths agree.
    private func hydrateCreator(currentInboxId: String) -> ConversationMember {
        if let conversationCreator {
            return conversationCreator.hydrateConversationMember(currentInboxId: currentInboxId)
        }
        return ConversationMember(
            profile: .empty(inboxId: conversation.creatorId),
            role: .superAdmin,
            isCurrentUser: conversation.creatorId == currentInboxId
        )
    }
}
