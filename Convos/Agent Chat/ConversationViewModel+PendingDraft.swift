import ConvosCore

extension ConversationViewModel {
    func applyPendingComposerDraft() {
        let environment: AppEnvironment = ConfigManager.shared.currentEnvironment
        let store = PendingComposerDraftStore(environment: environment)
        guard let draft = store.take(for: conversation.id) else { return }
        guard !messageText.isEmpty else {
            messageText = draft.text
            syncPasteDetectionBaseline()
            return
        }
        var existingText: String = messageText
        while existingText.last?.isWhitespace == true {
            existingText.removeLast()
        }
        messageText = "\(existingText)\n\n\(draft.text)"
        syncPasteDetectionBaseline()
    }
}
