import Foundation

extension ConversationViewModel {
    func onConversationAppeared() {
        isViewingConversation = true
        sendReadReceiptIfNeeded()
    }

    func onConversationDisappeared() {
        isViewingConversation = false
        pendingReadReceiptTask?.cancel()
        pendingReadReceiptTask = nil
    }

    func sendReadReceiptIfNeeded() {
        guard isViewingConversation else { return }
        guard !conversation.isDraft, !conversation.isPendingInvite else { return }
        // While the conversation is inactive (post-restore, MLS group hasn't
        // re-admitted this installation yet), libxmtp rejects the send with
        // `GroupError::GroupInactive`. The user-facing send-message path
        // already gates on `isInactive`; auto-fired read receipts need the
        // same gate so they don't spam the log every time the user opens
        // a still-inactive conversation.
        guard !isInactive else { return }
        guard sendReadReceipts else { return }

        let debounceInterval: TimeInterval = 1
        if let lastSent = lastReadReceiptSentAt, Date().timeIntervalSince(lastSent) < debounceInterval {
            guard pendingReadReceiptTask == nil else { return }
            let delay = debounceInterval - Date().timeIntervalSince(lastSent)
            let conversationId = conversation.id
            pendingReadReceiptTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.sendReadReceipt(for: conversationId)
                self?.pendingReadReceiptTask = nil
            }
            return
        }

        let conversationId = conversation.id
        Task { [weak self] in
            await self?.sendReadReceipt(for: conversationId)
        }
    }

    func sendReadReceipt(for conversationId: String) async {
        lastReadReceiptSentAt = Date()
        do {
            try await readReceiptWriter.sendReadReceipt(for: conversationId)
        } catch {
            Log.warning("Failed to send read receipt: \(error.localizedDescription)")
        }
    }
}
