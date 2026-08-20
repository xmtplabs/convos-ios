import ConvosCore

extension ConversationViewModel {
    func applyPendingComposerDraft() {
        let environment: AppEnvironment = ConfigManager.shared.currentEnvironment
        let store = PendingComposerDraftStore(environment: environment)
        guard let draft = store.take(for: conversation.id) else { return }
        messageText = draft.text
    }
}
