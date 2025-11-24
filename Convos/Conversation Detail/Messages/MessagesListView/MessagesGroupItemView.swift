import ConvosCore
import SwiftUI

struct MessagesGroupItemView: View {
    let message: AnyMessage
    let bubbleType: MessageBubbleType
    let showsSentStatus: Bool
    let onTapMessage: (AnyMessage) -> Void
    let onTapAvatar: (AnyMessage) -> Void

    @State private var isAppearing: Bool = true
    @State private var showingSentStatus: Bool = false

    private var animates: Bool {
        message.origin == .inserted
    }

    var body: some View {
        VStack(alignment: message.base.sender.isCurrentUser ? .trailing : .leading, spacing: 0.0) {
            switch message.base.content {
            case .text(let text):
                MessageBubble(
                    style: message.base.content.isEmoji ? .none : bubbleType,
                    message: text,
                    isOutgoing: message.base.sender.isCurrentUser,
                    profile: message.base.sender.profile,
                )
                .zIndex(200)
                .id("bubble-\(message.base.id)")
                .onTapGesture {
                    onTapMessage(message)
                }
                .scaleEffect(isAppearing ? 0.9 : 1.0)
                .rotationEffect(
                    .radians(
                        isAppearing
                        ? (message.base.source == .incoming ? -0.05 : 0.05)
                        : 0
                    )
                )
                .offset(
                    x: isAppearing
                    ? (message.base.source == .incoming ? -20 : 20)
                    : 0,
                    y: isAppearing ? 40 : 0
                )
            case .emoji(let text):
                EmojiBubble(
                    emoji: text,
                    isOutgoing: message.base.sender.isCurrentUser,
                    profile: message.base.sender.profile
                )
                .zIndex(200)
                .id("emoji-bubble-\(message.base.id)")
                .onTapGesture {
                    onTapMessage(message)
                }
                .opacity(isAppearing ? 0.0 : 1.0)
                .blur(radius: isAppearing ? 10.0 : 0.0)
                .scaleEffect(isAppearing ? 0.0 : 1.0)
                .rotationEffect(
                    .radians(
                        isAppearing
                        ? (message.base.source == .incoming ? -0.10 : 0.10)
                        : 0
                    )
                )
                .offset(
                    x: isAppearing
                    ? (message.base.source == .incoming ? -200 : 200)
                    : 0,
                    y: isAppearing ? 40 : 0
                )

            case .attachment(let url):
                AttachmentPlaceholder(url: url, isOutgoing: message.base.sender.isCurrentUser)
                    .id(message.base.id)
                    .onTapGesture {
                        onTapMessage(message)
                    }

            case .attachments(let urls):
                MultipleAttachmentsPlaceholder(urls: urls, isOutgoing: message.base.sender.isCurrentUser)
                    .id(message.base.id)
                    .onTapGesture {
                        onTapMessage(message)
                    }

            case .update:
                // Updates are handled at the item level, not here
                EmptyView()
            }

            if showsSentStatus {
                HStack(spacing: DesignConstants.Spacing.stepHalf) {
                    Text("Sent")
                    Image(systemName: "checkmark")
                }
//                .transition(.blurReplace)
                .opacity(showingSentStatus ? 1.0 : 0.0)
                .blur(radius: showingSentStatus ? 0.0 : 10.0)
                .scaleEffect(showingSentStatus ? 1.0 : 0.8)
                .padding(.vertical, DesignConstants.Spacing.stepX)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .zIndex(60)
                .id("sent-status")
            }
        }
        .onChange(of: showsSentStatus, initial: true) {
            withAnimation(animates ? .spring(response: 0.35, dampingFraction: 0.8) : .none) {
                showingSentStatus = showsSentStatus
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showsSentStatus)
        .id("messages-group-item-view-\(message.base.id)")
        .transition(
            .asymmetric(
                insertion: .identity,      // no transition on insert
                removal: .opacity
            )
        )
        .onAppear {
            guard isAppearing else { return }

            if animates {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isAppearing = false
                }
            } else {
                withAnimation(.none) {
                    isAppearing = false
                }
            }
        }
    }
}

// MARK: - Placeholder Views for Attachments

private struct AttachmentPlaceholder: View {
    let url: URL
    let isOutgoing: Bool

    var body: some View {
        HStack {
            if isOutgoing { Spacer() }

            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 200, height: 150)
                .overlay(
                    VStack {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        Text("Attachment")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                )

            if !isOutgoing { Spacer() }
        }
    }
}

private struct MultipleAttachmentsPlaceholder: View {
    let urls: [URL]
    let isOutgoing: Bool

    var body: some View {
        HStack {
            if isOutgoing { Spacer() }

            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 200, height: 150)
                .overlay(
                    VStack {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        Text("\(urls.count) Attachments")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                )

            if !isOutgoing { Spacer() }
        }
    }
}

// MARK: - Previews

#Preview("Text Message - Incoming") {
    MessagesGroupItemView(
        message: .message(Message.mock(
            text: "Hello, how are you doing today?",
            sender: .mock(isCurrentUser: false),
            status: .published
        ), .existing),
        bubbleType: .normal,
        showsSentStatus: false,
        onTapMessage: { _ in },
        onTapAvatar: { _ in }
    )
    .padding()
}

#Preview("Text Message - Outgoing") {
    MessagesGroupItemView(
        message: .message(Message.mock(
            text: "I'm doing great, thanks for asking!",
            sender: .mock(isCurrentUser: true),
            status: .published
        ), .existing),
        bubbleType: .tailed,
        showsSentStatus: true,
        onTapMessage: { _ in },
        onTapAvatar: { _ in }
    )
    .padding()
}

#Preview("Unpublished Message") {
    MessagesGroupItemView(
        message: .message(Message.mock(
            text: "This message is still sending...",
            sender: .mock(isCurrentUser: true),
            status: .unpublished
        ), .existing),
        bubbleType: .normal,
        showsSentStatus: false,
        onTapMessage: { _ in },
        onTapAvatar: { _ in }
    )
    .padding()
}

#Preview("Emoji Message") {
    MessagesGroupItemView(
        message: .message(Message.mock(
            text: "😊👍🎉",
            sender: .mock(isCurrentUser: false),
            status: .published
        ), .existing),
        bubbleType: .tailed,
        showsSentStatus: false,
        onTapMessage: { _ in },
        onTapAvatar: { _ in }
    )
    .padding()
}
