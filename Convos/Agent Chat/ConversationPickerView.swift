import ConvosCore
import SwiftUI

struct ConversationPickerView: View {
    let mode: ConversationPickerMode
    let draftStore: PendingComposerDraftStore
    let onPick: (() -> Void)?
    @State private var viewModel: ConversationPickerViewModel
    @Environment(\.dismiss) private var dismiss: DismissAction

    init(
        mode: ConversationPickerMode,
        session: any SessionManagerProtocol,
        draftStore: PendingComposerDraftStore,
        onPick: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.draftStore = draftStore
        self.onPick = onPick
        _viewModel = State(initialValue: ConversationPickerViewModel(session: session))
    }

    var body: some View {
        NavigationStack {
            List(viewModel.filteredConversations) { conversation in
                let action = { choose(conversation) }
                Button(action: action) {
                    conversationRow(conversation)
                }
            }
            .searchable(text: $viewModel.query, prompt: "Convos")
            .overlay { emptyState }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.colorTextPrimary)
                .frame(width: DesignConstants.Spacing.step8x)
            Text(conversation.computedDisplayName)
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.filteredConversations.isEmpty {
            ContentUnavailableView(
                "No convos found",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Try another search.")
            )
        }
    }

    private func choose(_ conversation: Conversation) {
        switch mode {
        case .stageDraft(let text):
            let draft = PendingComposerDraft(
                conversationId: conversation.id,
                text: text,
                stagedAt: Date()
            )
            draftStore.stage(draft)
        }
        dismiss()
        onPick?()
        DispatchQueue.main.asyncAfter(deadline: .now() + Constant.navigationDelay) {
            NotificationCenter.default.post(
                name: .conversationNotificationTapped,
                object: nil,
                userInfo: [
                    // inboxId is a sentinel marker here; routing uses conversationId alone.
                    "inboxId": "composer-draft",
                    "conversationId": conversation.id,
                ]
            )
        }
    }

    private enum Constant {
        static let navigationDelay: TimeInterval = 0.3
    }
}
