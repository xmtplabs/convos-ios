import ConvosCore
import SwiftUI

struct PinnedConversationsSection: View {
    let pinnedConversations: [Conversation]
    let viewModel: ConversationsViewModel
    @Binding var conversationPendingDeletion: Conversation?
    let onSelectConversation: (Conversation) -> Void

    private var shouldUseGrid: Bool {
        pinnedConversations.count >= 3
    }

    private var conversationRows: [[Conversation]] {
        stride(from: 0, to: pinnedConversations.count, by: 3).map { index in
            let endIndex = min(index + 3, pinnedConversations.count)
            return Array(pinnedConversations[index..<endIndex])
        }
    }

    @ViewBuilder
    private func conversationItem(_ conversation: Conversation) -> some View {
        let selectAction = { onSelectConversation(conversation) }

        PinnedConversationItem(conversation: conversation)
            .contentShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
            .onTapGesture(perform: selectAction)
            .contextMenu {
                conversationContextMenuContent(
                    conversation: conversation,
                    viewModel: viewModel,
                    onDelete: { conversationPendingDeletion = conversation }
                )
            }
            .confirmationDialog(
                "This convo will be deleted immediately.",
                isPresented: Binding(
                    get: { conversationPendingDeletion?.id == conversation.id },
                    set: { if !$0 { conversationPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    viewModel.leave(conversation: conversation)
                    conversationPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    conversationPendingDeletion = nil
                }
            }
            .id(conversation.id)
    }

    var body: some View {
        Group {
            if shouldUseGrid {
                gridLayout
            } else {
                horizontalLayout
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: shouldUseGrid)
    }

    private var horizontalLayout: some View {
        HStack(spacing: DesignConstants.Spacing.step6x) {
            ForEach(pinnedConversations) { conversation in
                conversationItem(conversation)
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .accessibilityLabel("Pinned conversations")
        .accessibilityIdentifier("pinned-conversations-section")
    }

    private var gridLayout: some View {
        VStack(spacing: DesignConstants.Spacing.step6x) {
            ForEach(Array(conversationRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: DesignConstants.Spacing.step6x) {
                    ForEach(row) { conversation in
                        conversationItem(conversation)
                    }
                }
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .accessibilityLabel("Pinned conversations")
        .accessibilityIdentifier("pinned-conversations-section")
    }
}

#Preview {
    @Previewable @State var conversationPendingDeletion: Conversation?
    let convos = ConvosClient.mock()
    let viewModel = ConversationsViewModel(session: convos.session)

    PinnedConversationsSection(
        pinnedConversations: [
            .mock(isUnread: true, isPinned: true),
            .mock(isUnread: false, isPinned: true),
            .mock(isUnread: true, isPinned: true)
        ],
        viewModel: viewModel,
        conversationPendingDeletion: $conversationPendingDeletion,
        onSelectConversation: { _ in }
    )
}
