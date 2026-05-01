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
