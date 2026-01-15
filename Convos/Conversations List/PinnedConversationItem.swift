import ConvosCore
import SwiftUI

struct PinnedConversationItem: View {
    let conversation: Conversation
    @State private var showingMessagePreview: Bool = false

    private var hasUnreadMessage: Bool {
        conversation.isUnread && conversation.lastMessage != nil
    }

    var body: some View {
        VStack(alignment: .center, spacing: DesignConstants.Spacing.step2x) {
            ZStack(alignment: .top) {
                ConversationAvatarView(conversation: conversation, conversationImage: nil)
                    .frame(width: 96, height: 96)

                if hasUnreadMessage, let lastMessage = conversation.lastMessage {
                    messagePreviewOverlay(text: lastMessage.text)
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .opacity
                        ))
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showingMessagePreview)
                }
            }

            HStack(spacing: DesignConstants.Spacing.stepX) {
                Text(conversation.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)

                if conversation.isUnread {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 8.0, height: 8.0)
                }
            }
            .padding(DesignConstants.Spacing.step3x)
        }
        .frame(width: 96)
        .onAppear {
            if hasUnreadMessage {
                withAnimation {
                    showingMessagePreview = true
                }
            }
        }
        .onChange(of: hasUnreadMessage) { _, newValue in
            withAnimation {
                showingMessagePreview = newValue
            }
        }
    }

    @ViewBuilder
    private func messagePreviewOverlay(text: String) -> some View {
        if showingMessagePreview {
            Text(text)
                .font(.caption2)
                .foregroundColor(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, DesignConstants.Spacing.step2x)
                .frame(width: 96, alignment: .center)
                .background(Color.colorBackgroundRaised)
                .cornerRadius(DesignConstants.CornerRadius.medium)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                        .inset(by: 0.5)
                        .stroke(Color.colorBorderSubtle, lineWidth: 1)
                )
                .offset(y: -4)
        }
    }
}

#Preview {
    HStack(spacing: DesignConstants.Spacing.step4x) {
        PinnedConversationItem(conversation: .mock(isUnread: false))
        PinnedConversationItem(conversation: .mock(isUnread: true))
        PinnedConversationItem(conversation: .mock(isUnread: true, lastMessageText: "Hello!"))
    }
    .padding()
}
