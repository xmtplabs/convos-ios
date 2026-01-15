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
        stride(from: 0, to: pinnedConversations.count, by: 3).map { startIndex in
            Array(pinnedConversations[startIndex..<min(startIndex + 3, pinnedConversations.count)])
        }
    }

    @ViewBuilder
    private func conversationItem(_ conversation: Conversation) -> some View {
        PinnedConversationItem(conversation: conversation)
            .id(conversation.id)
            .contentShape(.interaction, RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
            .simultaneousGesture(
                TapGesture()
                    .onEnded { _ in
                        onSelectConversation(conversation)
                    }
            )
            .contextMenu {
                Button {
                    viewModel.togglePin(conversation: conversation)
                } label: {
                    Label(
                        conversation.isPinned ? "Unpin" : "Pin",
                        systemImage: conversation.isPinned ? "pin.slash.fill" : "pin.fill"
                    )
                }

                Button {
                    viewModel.toggleReadState(conversation: conversation)
                } label: {
                    Label(
                        conversation.isUnread ? "Mark as Read" : "Mark as Unread",
                        systemImage: conversation.isUnread ? "checkmark.message.fill" : "message.badge.fill"
                    )
                }

                Button {
                    viewModel.toggleMute(conversation: conversation)
                } label: {
                    Label(
                        conversation.isMuted ? "Unmute" : "Mute",
                        systemImage: conversation.isMuted ? "bell.fill" : "bell.slash.fill"
                    )
                }

                Divider()

                Button(role: .destructive) {
                    conversationPendingDeletion = conversation
                } label: {
                    Label("Delete", systemImage: "trash")
                }
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
        HStack(spacing: DesignConstants.Spacing.step4x) {
            ForEach(pinnedConversations) { conversation in
                conversationItem(conversation)
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
    }

    private var gridLayout: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            ForEach(conversationRows, id: \.first?.id) { row in
                HStack(spacing: DesignConstants.Spacing.step4x) {
                    ForEach(row) { conversation in
                        conversationItem(conversation)
                    }
                }
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
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
