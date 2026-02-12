import ConvosCore
import SwiftUI

struct MessagesGroupItemView: View {
    let message: AnyMessage
    let bubbleType: MessageBubbleType
    let onTapAvatar: (AnyMessage) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onReply: (AnyMessage) -> Void

    @State private var isAppearing: Bool = true
    @State private var hasAnimated: Bool = false
    @State private var swipeOffset: CGFloat = 0

    private var animates: Bool {
        message.origin == .inserted
    }

    var body: some View {
        VStack(alignment: message.base.sender.isCurrentUser ? .trailing : .leading, spacing: 0.0) {
            if case .reply(let reply, _) = message {
                ReplyReferenceView(
                    replySender: reply.sender,
                    parentMessage: reply.parentMessage,
                    isOutgoing: message.base.sender.isCurrentUser,
                    onTapAvatar: { onTapAvatar(.message(reply.parentMessage, .existing)) }
                )
            }
            switch message.base.content {
            case .text(let text):
                MessageBubble(
                    style: message.base.content.isEmoji ? .none : bubbleType,
                    message: text,
                    isOutgoing: message.base.sender.isCurrentUser,
                    profile: message.base.sender.profile
                )
                .messageInteractions(
                    message: message,
                    bubbleStyle: message.base.content.isEmoji ? .none : bubbleType,
                    onSwipeOffsetChanged: { swipeOffset = $0 },
                    onSwipeEnded: { triggered in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            swipeOffset = 0
                        }
                        if triggered { onReply(message) }
                    }
                )
                .offset(x: swipeOffset)
                .background(alignment: .leading) {
                    if swipeOffset > 0 {
                        let progress = min(swipeOffset / 60.0, 1.0)
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .foregroundStyle(.tertiary)
                            .scaleEffect(0.4 + progress * 0.6)
                            .opacity(Double(progress))
                            .accessibilityHidden(true)
                    }
                }
                .zIndex(200)
                .id("bubble-\(message.base.id)")
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
                .messageInteractions(
                    message: message,
                    bubbleStyle: .none,
                    onSwipeOffsetChanged: { swipeOffset = $0 },
                    onSwipeEnded: { triggered in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            swipeOffset = 0
                        }
                        if triggered { onReply(message) }
                    }
                )
                .offset(x: swipeOffset)
                .background(alignment: .leading) {
                    if swipeOffset > 0 {
                        let progress = min(swipeOffset / 60.0, 1.0)
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .foregroundStyle(.tertiary)
                            .scaleEffect(0.4 + progress * 0.6)
                            .opacity(Double(progress))
                    }
                }
                .zIndex(200)
                .id("emoji-bubble-\(message.base.id)")
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

            case .invite(let invite):
                MessageInviteContainerView(
                    invite: invite,
                    style: bubbleType,
                    isOutgoing: message.base.source == .outgoing,
                    profile: message.base.sender.profile,
                    onTapInvite: onTapInvite,
                ) {
                    onTapAvatar(message)
                }
                .zIndex(200)
                .id("message-invite-\(message.base.id)")
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

            case .attachment(let url):
                AttachmentPlaceholder(url: url, isOutgoing: message.base.sender.isCurrentUser)
                    .id(message.base.id)

            case .attachments(let urls):
                MultipleAttachmentsPlaceholder(urls: urls, isOutgoing: message.base.sender.isCurrentUser)
                    .id(message.base.id)

            case .update:
                // Updates are handled at the item level, not here
                EmptyView()
            }
        }
        .id("messages-group-item-view-\(message.base.id)")
        .transition(
            .asymmetric(
                insertion: .identity,      // no transition on insert
                removal: .opacity
            )
        )
        .onAppear {
            guard isAppearing, !hasAnimated else { return }
            hasAnimated = true

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
                .accessibilityLabel("Attachment")

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
                        Image(systemName: "photo.fill.on.rectangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        Text("\(urls.count) Attachments")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                )
                .accessibilityLabel("\(urls.count) attachments")

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
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in }
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
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in }
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
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in }
    )
    .padding()
}

#Preview("Emoji Message") {
    MessagesGroupItemView(
        message: .message(Message.mock(
            text: "🎉",
            sender: .mock(isCurrentUser: false),
            status: .published
        ), .existing),
        bubbleType: .tailed,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in }
    )
    .padding()
}

#Preview("Reply - Outgoing") {
    MessagesGroupItemView(
        message: .reply(MessageReply.mock(
            text: "I agree with that!",
            sender: .mock(isCurrentUser: true),
            parentText: "What do you think about the new design?",
            parentSender: .mock(isCurrentUser: false, name: "Jane")
        ), .existing),
        bubbleType: .tailed,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in }
    )
    .padding()
}

#Preview("Reply - Incoming") {
    MessagesGroupItemView(
        message: .reply(MessageReply.mock(
            text: "Sounds good to me",
            sender: .mock(isCurrentUser: false, name: "Alex"),
            parentText: "Let's meet at 3pm tomorrow",
            parentSender: .mock(isCurrentUser: true)
        ), .existing),
        bubbleType: .tailed,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in }
    )
    .padding()
}
