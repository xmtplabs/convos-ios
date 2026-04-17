import ConvosCore
import Foundation
import Observation

extension ConversationViewModel {
    func setupTypingIndicatorHandler() {
        let manager = typingIndicatorManager
        Task {
            await messagingService.sessionStateManager.setTypingIndicatorHandler { conversationId, senderInboxId, isTyping in
                Task { @MainActor in
                    manager.handleTypingEvent(
                        conversationId: conversationId,
                        senderInboxId: senderInboxId,
                        isTyping: isTyping
                    )
                }
            }
        }
    }

    func observeTypingIndicators(_ manager: TypingIndicatorManager) {
        withObservationTracking {
            _ = manager.typingMembersByConversation[conversation.id]
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateTypingMembers(from: manager)
                self.observeTypingIndicators(manager)
            }
        }
        updateTypingMembers(from: manager)
    }

    func updateTypingMembers(from manager: TypingIndicatorManager) {
        let typerInboxIds = manager.typers(for: conversation.id)
        let members = conversation.members.filter { member in
            typerInboxIds.contains { $0.inboxId == member.profile.inboxId }
        }
        typingMembers = members
    }

    func clearTypingForNewMessages(old: [MessagesListItemType], new: [MessagesListItemType]) {
        let oldLastId = old.lastMessageId
        let newLastId = new.lastMessageId
        guard oldLastId != newLastId,
              let lastItem = new.last,
              case .messages(let group) = lastItem,
              !group.sender.isCurrentUser else { return }
        typingIndicatorManager.handleMessageReceived(
            conversationId: conversation.id,
            senderInboxId: group.sender.profile.inboxId
        )
        updateTypingMembers(from: typingIndicatorManager)
    }

    func scheduleVoiceMemoTranscriptionsIfNeeded(in items: [MessagesListItemType]) {
        let service = voiceMemoTranscriptionService
        guard service.hasSpeechPermission() else { return }
        let conversationId = conversation.id
        for item in items {
            guard case .messages(let group) = item else { continue }
            for message in group.messages {
                guard !message.senderIsCurrentUser else { continue }
                guard let attachment = message.content.primaryVoiceMemoAttachment else { continue }
                let messageId = message.messageId
                let attachmentKey = attachment.key
                let mimeType = attachment.mimeType ?? "audio/m4a"
                Task.detached(priority: .utility) {
                    await service.enqueueIfNeeded(
                        messageId: messageId,
                        conversationId: conversationId,
                        attachmentKey: attachmentKey,
                        mimeType: mimeType
                    )
                }
            }
        }
    }

    func stopTyping() {
        guard isTypingSent else { return }
        isTypingSent = false
        typingThrottleDate = nil
        typingResetTask?.cancel()
        typingResetTask = nil
        pendingTypingIndicatorTask?.cancel()
        let conversationId = conversation.id
        pendingTypingIndicatorTask = Task { [weak self] in
            guard let self else { return }
            try? await self.messagingService.sendTypingIndicator(isTyping: false, for: conversationId)
        }
    }

    func handleTextChanged() {
        if messageText.isEmpty {
            stopTyping()
            return
        }

        let now = Date()
        if let lastSent = typingThrottleDate, now.timeIntervalSince(lastSent) < Self.typingThrottleInterval {
            typingResetTask?.cancel()
            typingResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.typingResetInterval))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.stopTyping()
                }
            }
            return
        }

        typingThrottleDate = now

        typingResetTask?.cancel()
        typingResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.typingResetInterval))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.stopTyping()
            }
        }

        pendingTypingIndicatorTask?.cancel()
        let conversationId = conversation.id
        pendingTypingIndicatorTask = Task { [weak self] in
            guard let self else { return }
            try? await self.messagingService.sendTypingIndicator(isTyping: true, for: conversationId)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.isTypingSent = true
            }
        }
    }

    var messagesWithTypingIndicator: [MessagesListItemType] {
        guard !typingMembers.isEmpty else { return messages }

        if typingMembers.count == 1 {
            return messagesWithSingleTyper(typingMembers[0])
        }
        return messagesWithMultipleTypers(typingMembers)
    }

    func messagesWithSingleTyper(_ typer: ConversationMember) -> [MessagesListItemType] {
        if let lastIndex = messages.lastIndex(where: { if case .messages = $0 { return true }; return false }),
           case .messages(let lastGroup) = messages[lastIndex],
           lastGroup.sender.profile.inboxId == typer.profile.inboxId {
            var updated = messages
            let updatedGroup = MessagesGroup(
                id: lastGroup.id,
                sender: lastGroup.sender,
                messages: lastGroup.rawMessages,
                isLastGroup: lastGroup.isLastGroup,
                isLastGroupSentByCurrentUser: lastGroup.isLastGroupSentByCurrentUser,
                showsTypingIndicator: true,
                allTypingMembers: [typer],
                readByProfiles: lastGroup.readByProfiles,
                onlyVisibleToSender: lastGroup.onlyVisibleToSender,
                isLastGroupBeforeOtherMembers: lastGroup.isLastGroupBeforeOtherMembers,
                voiceMemoTranscripts: lastGroup.voiceMemoTranscripts
            )
            updated[lastIndex] = .messages(updatedGroup)
            return updated
        }

        let typingGroup = MessagesGroup(
            id: "typing-indicator",
            sender: typer,
            messages: [],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false,
            showsTypingIndicator: true
        )
        return messages + [.messages(typingGroup)]
    }

    func messagesWithMultipleTypers(_ typers: [ConversationMember]) -> [MessagesListItemType] {
        let typingGroup = MessagesGroup(
            id: "typing-indicator-multi",
            sender: typers[0],
            messages: [],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false,
            showsTypingIndicator: true,
            allTypingMembers: typers
        )
        return messages + [.messages(typingGroup)]
    }

    static let typingThrottleInterval: TimeInterval = 5
    static let typingResetInterval: TimeInterval = 10
}
