import ConvosCore
import SwiftUI

struct PinnedConversationItem: View {
    let conversation: Conversation
    var avatarSize: CGFloat = 96
    var animateOnAppear: Bool = true
    @State private var showingMessagePreview: Bool = false

    private var hasUnreadMessage: Bool {
        conversation.isUnread && conversation.lastMessage != nil
    }

    private var pinnedAccessibilityLabel: String {
        var parts: [String] = [conversation.title, "pinned"]
        if conversation.isUnread { parts.append("unread") }
        if conversation.isMuted { parts.append("muted") }
        if hasUnreadMessage, let lastMessage = conversation.lastMessage {
            parts.append(lastMessage.text)
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .center, spacing: DesignConstants.Spacing.step2x) {
            ConversationAvatarView(conversation: conversation, conversationImage: nil)
                .frame(width: avatarSize, height: avatarSize)
                .padding(.top, DesignConstants.Spacing.stepX)
                .overlay(alignment: .top) {
                    if hasUnreadMessage, let lastMessage = conversation.lastMessage {
                        messagePreviewOverlay(text: lastMessage.text)
                            .accessibilityHidden(true)
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
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if conversation.isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                        .transition(.scale.combined(with: .opacity))
                }

                if conversation.isUnread {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 8.0, height: 8.0)
                        .accessibilityHidden(true)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: conversation.isMuted)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: conversation.isUnread)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pinnedAccessibilityLabel)
        .accessibilityIdentifier("pinned-conversation-\(conversation.id)")
        .onAppear {
            if hasUnreadMessage {
                if animateOnAppear {
                    withAnimation {
                        showingMessagePreview = true
                    }
                } else {
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
                .font(.caption)
                .foregroundStyle(.colorTextPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, DesignConstants.Spacing.step2x)
                .frame(width: avatarSize, alignment: .center)
                .background(Color.colorBackgroundRaised)
                .cornerRadius(DesignConstants.CornerRadius.medium)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                        .inset(by: 0.5)
                        .stroke(Color.colorBorderSubtle, lineWidth: 1)
                )

        }
    }
}

struct PinnedConversationContextPreview: View {
    let conversation: Conversation
    var avatarSize: CGFloat = 115

    var body: some View {
        VStack(alignment: .center, spacing: DesignConstants.Spacing.step2x) {
            if conversation.isUnread, let lastMessage = conversation.lastMessage {
                Text(lastMessage.text)
                    .font(.caption)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .padding(.vertical, DesignConstants.Spacing.step2x)
                    .frame(width: avatarSize, alignment: .center)
                    .background(Color.colorBackgroundRaised)
                    .cornerRadius(DesignConstants.CornerRadius.medium)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                            .inset(by: 0.5)
                            .stroke(Color.colorBorderSubtle, lineWidth: 1)
                    )
            }

            ConversationAvatarView(conversation: conversation, conversationImage: nil)
                .frame(width: avatarSize, height: avatarSize)

            HStack(spacing: DesignConstants.Spacing.stepX) {
                Text(conversation.title)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if conversation.isMuted {
                    Image(systemName: "bell.slash.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if conversation.isUnread {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 8.0, height: 8.0)
                }
            }
        }
        .frame(width: avatarSize)
    }
}

#Preview {
    HStack(spacing: DesignConstants.Spacing.step4x) {
        PinnedConversationItem(conversation: .mock(isUnread: false))
        PinnedConversationItem(conversation: .mock(isUnread: true))
        PinnedConversationItem(conversation: .mock(isUnread: true, lastMessageText: "Hello!"))
        PinnedConversationItem(conversation: .mock(isMuted: true))
    }
    .padding()
}
