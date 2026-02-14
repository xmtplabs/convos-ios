import ConvosCore
import ConvosLogging
import SwiftUI

struct MessagesGroupView: View {
    let group: MessagesGroup
    let shouldBlurPhotos: Bool
    let onTapAvatar: (AnyMessage) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onReply: (AnyMessage) -> Void
    let onDoubleTap: (AnyMessage) -> Void
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void

    @State private var isAppearing: Bool = true
    @State private var hasAnimated: Bool = false

    private var animates: Bool {
        group.messages.first?.origin == .inserted
    }

    private var avatarWidth: CGFloat {
        group.sender.isCurrentUser ? 0 : DesignConstants.ImageSizes.smallAvatar + DesignConstants.Spacing.step2x
    }

    private var avatarSize: CGFloat {
        DesignConstants.ImageSizes.smallAvatar
    }

    private var avatarSpacing: CGFloat {
        DesignConstants.Spacing.step2x
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            let allMessages = group.allMessages
            ForEach(Array(allMessages.enumerated()), id: \.element.base.id) { index, message in
                let isReply = if case .reply = message { true } else { false }
                let isFullWidthAttachment = message.base.content.isAttachment

                if index == 0 && !group.sender.isCurrentUser && !isFullWidthAttachment && !isReply {
                    Text(group.sender.profile.displayName)
                        .scaleEffect(isAppearing ? 0.9 : 1.0)
                        .opacity(isAppearing ? 0.0 : 1.0)
                        .offset(
                            x: 0.0,
                            y: isAppearing ? 100 : 0
                        )
                        .blur(radius: isAppearing ? 10.0 : 0.0)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.leading, avatarWidth + DesignConstants.Spacing.step4x + DesignConstants.Spacing.step3x)
                        .padding(.bottom, DesignConstants.Spacing.stepHalf)
                }

                let lastMessage = group.messages.last
                let isLast = message == lastMessage
                let bubbleType: MessageBubbleType = isLast ? .tailed : .normal
                let isLastInGroup = message == group.messages.last
                // Show "Sent" status for the last message in the last group sent by current user,
                // but only if it's published (not still sending)
                let showsSentStatus = isLastInGroup && group.isLastGroupSentByCurrentUser && message.base.status == .published

                HStack(alignment: .bottom, spacing: avatarSpacing) {
                    // Show avatar spacer for incoming non-attachment messages only
                    if !group.sender.isCurrentUser && !isFullWidthAttachment {
                        Color.clear
                            .frame(width: avatarSize, height: avatarSize)
                    }

                    MessagesGroupItemView(
                        message: message,
                        bubbleType: bubbleType,
                        shouldBlurPhotos: shouldBlurPhotos,
                        onTapAvatar: onTapAvatar,
                        onTapInvite: onTapInvite,
                        onReply: onReply,
                        onDoubleTap: onDoubleTap,
                        onPhotoRevealed: onPhotoRevealed,
                        onPhotoHidden: onPhotoHidden,
                        onPhotoDimensionsLoaded: onPhotoDimensionsLoaded
                    )
                    .zIndex(100)
                    .id("messages-group-item-\(message.differenceIdentifier)")
                    .transition(
                        .asymmetric(
                            insertion: .identity,
                            removal: .opacity
                        )
                    )
                    .overlay(alignment: .bottomLeading) {
                        if isLast && !group.sender.isCurrentUser {
                            MessageAvatarView(profile: group.sender.profile, size: avatarSize)
                                .offset(x: -(avatarSize + avatarSpacing))
                                .onTapGesture {
                                    onTapAvatar(message)
                                }
                                .scaleEffect(isAppearing ? 0.9 : 1.0)
                                .opacity(isAppearing ? 0.0 : 1.0)
                                .offset(
                                    x: isAppearing ? -80 : 0,
                                    y: 0.0
                                )
                                .id("profile-\(group.id)")
                                .accessibilityLabel("View \(group.sender.profile.displayName)'s profile")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                }
                .padding(.leading, !group.sender.isCurrentUser && !isFullWidthAttachment ? DesignConstants.Spacing.step4x : 0)

                if !message.base.reactions.isEmpty {
                    ReactionIndicatorView(
                        reactions: message.base.reactions,
                        isOutgoing: message.base.sender.isCurrentUser,
                        onTap: { onTapReactions(message) }
                    )
                    .padding(.leading, message.base.sender.isCurrentUser ? 0 : (isFullWidthAttachment ? DesignConstants.Spacing.step4x : avatarWidth + avatarSpacing + DesignConstants.Spacing.step2x))
                    .padding(.trailing, message.base.sender.isCurrentUser ? DesignConstants.Spacing.step4x : 0)
                    .padding(.bottom, DesignConstants.Spacing.stepX)
                    .transition(.identity)
                    .zIndex(50)
                    .id("reactions-\(message.differenceIdentifier)")
                }

                if showsSentStatus {
                    HStack(spacing: DesignConstants.Spacing.stepHalf) {
                        Spacer()
                        Text("Sent")
                        Image(systemName: "checkmark")
                    }
                    .transition(.blurReplace)
                    .padding(.vertical, DesignConstants.Spacing.stepX)
                    .padding(.leading, DesignConstants.Spacing.step2x)
                    .padding(.trailing, DesignConstants.Spacing.step4x)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .zIndex(-1)
                    .id("sent-status-\(message.differenceIdentifier)")
                    .accessibilityLabel("Message sent")
                }
            }
        }
        .id("message-group-container-\(group.id)")
        .transition(
            .asymmetric(
                insertion: .identity,
                removal: .opacity
            )
        )
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: group)
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
        .id("messages-group-\(group.id)")
    }
}

#Preview("All Message Permutations") {
    let alice = ConversationMember.mock(isCurrentUser: false, name: "Alice")
    let me = ConversationMember.mock(isCurrentUser: true)
    let reactions: [MessageReaction] = [
        .mock(emoji: "❤️", sender: .mock(isCurrentUser: true)),
        .mock(emoji: "😂", sender: .mock(isCurrentUser: false, name: "Bob")),
    ]
    let photoURL = "https://picsum.photos/400/300"
    let photoAttachment = HydratedAttachment(key: photoURL, width: 400, height: 300)
    let hiddenPhoto = HydratedAttachment(key: photoURL, isHiddenByOwner: true, width: 400, height: 300)

    let groups: [MessagesGroup] = [
        // -- Text messages --
        MessagesGroup(
            id: "text-incoming",
            sender: alice,
            messages: [
                .message(Message.mock(text: "Standard text message", sender: alice), .existing),
                .message(Message.mock(text: "With reactions", sender: alice, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "text-outgoing",
            sender: me,
            messages: [
                .message(Message.mock(text: "Standard text message", sender: me), .existing),
                .message(Message.mock(text: "With reactions", sender: me, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Emoji messages --
        MessagesGroup(
            id: "emoji-incoming",
            sender: alice,
            messages: [
                .message(Message.mock(text: "🔥", sender: alice), .existing),
                .message(Message.mock(text: "🎉", sender: alice, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "emoji-outgoing",
            sender: me,
            messages: [
                .message(Message.mock(text: "❤️", sender: me), .existing),
                .message(Message.mock(text: "🙌", sender: me, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Photo messages --
        MessagesGroup(
            id: "photo-incoming",
            sender: alice,
            messages: [
                .message(Message.mock(content: .attachment(photoAttachment), sender: alice), .existing),
                .message(Message.mock(content: .attachment(photoAttachment), sender: alice, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "photo-outgoing",
            sender: me,
            messages: [
                .message(Message.mock(content: .attachment(photoAttachment), sender: me), .existing),
                .message(Message.mock(content: .attachment(photoAttachment), sender: me, reactions: reactions), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Hidden/blurred photos --
        MessagesGroup(
            id: "photo-hidden",
            sender: alice,
            messages: [
                .message(Message.mock(content: .attachment(hiddenPhoto), sender: alice), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Link messages --
        MessagesGroup(
            id: "link-incoming",
            sender: alice,
            messages: [
                .message(Message.mock(text: "Check out https://convos.org", sender: alice), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "link-outgoing",
            sender: me,
            messages: [
                .message(Message.mock(text: "Look at this https://github.com/xmtplabs/convos-ios", sender: me), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Invite messages --
        MessagesGroup(
            id: "invite-incoming",
            sender: alice,
            messages: [
                .message(Message.mock(content: .invite(.mock), sender: alice), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "invite-outgoing",
            sender: me,
            messages: [
                .message(Message.mock(content: .invite(.mock), sender: me), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Text reply to text --
        MessagesGroup(
            id: "reply-text-to-text",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    text: "Totally agree!",
                    sender: alice,
                    parentText: "What do you think about the new design?",
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "reply-text-to-text-out",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    text: "Sounds good to me",
                    sender: me,
                    parentText: "Let's meet at 3pm tomorrow",
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Text reply to photo --
        MessagesGroup(
            id: "reply-text-to-photo",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    text: "Great photo!",
                    sender: alice,
                    parentContent: .attachment(photoAttachment),
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "reply-text-to-photo-out",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    text: "Love this shot",
                    sender: me,
                    parentContent: .attachment(photoAttachment),
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Text reply to emoji --
        MessagesGroup(
            id: "reply-text-to-emoji",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    text: "Haha same!",
                    sender: alice,
                    parentContent: .emoji("🔥"),
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "reply-text-to-emoji-out",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    text: "Right back at you",
                    sender: me,
                    parentContent: .emoji("❤️"),
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Text reply to invite --
        MessagesGroup(
            id: "reply-text-to-invite",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    text: "I'll join!",
                    sender: alice,
                    parentContent: .invite(.mock),
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Photo reply to text --
        MessagesGroup(
            id: "reply-photo-to-text",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    sender: alice,
                    replyContent: .attachment(photoAttachment),
                    parentText: "Show me what you mean",
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "reply-photo-to-text-out",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    sender: me,
                    replyContent: .attachment(photoAttachment),
                    parentText: "Can you send a pic?",
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Photo reply to photo --
        MessagesGroup(
            id: "reply-photo-to-photo",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    sender: alice,
                    replyContent: .attachment(photoAttachment),
                    parentContent: .attachment(photoAttachment),
                    parentSender: me
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Photo reply to emoji --
        MessagesGroup(
            id: "reply-photo-to-emoji",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    sender: me,
                    replyContent: .attachment(photoAttachment),
                    parentContent: .emoji("🙌"),
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Photo reply to invite --
        MessagesGroup(
            id: "reply-photo-to-invite",
            sender: me,
            messages: [
                .reply(MessageReply.mock(
                    sender: me,
                    replyContent: .attachment(photoAttachment),
                    parentContent: .invite(.mock),
                    parentSender: alice
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Reactions on replies --
        MessagesGroup(
            id: "reply-with-reactions",
            sender: alice,
            messages: [
                .reply(MessageReply.mock(
                    text: "Love it!",
                    sender: alice,
                    parentText: "Check out this idea",
                    parentSender: me,
                    reactions: reactions
                ), .existing),
                .reply(MessageReply.mock(
                    sender: alice,
                    replyContent: .attachment(photoAttachment),
                    parentText: "Send me a photo",
                    parentSender: me,
                    reactions: reactions
                ), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),

        // -- Sent status --
        MessagesGroup(
            id: "sent-status",
            sender: me,
            messages: [
                .message(Message.mock(text: "Last message with sent status", sender: me), .existing),
            ],
            isLastGroup: true,
            isLastGroupSentByCurrentUser: true
        ),
    ]

    ScrollView {
        VStack(spacing: 0) {
            ForEach(groups) { group in
                MessagesGroupView(
                    group: group,
                    shouldBlurPhotos: true,
                    onTapAvatar: { _ in },
                    onTapInvite: { _ in },
                    onTapReactions: { _ in },
                    onReply: { _ in },
                    onDoubleTap: { _ in },
                    onPhotoRevealed: { _ in },
                    onPhotoHidden: { _ in },
                    onPhotoDimensionsLoaded: { _, _, _ in }
                )
            }
        }
    }
    .background(.colorBackgroundSurfaceless)
}
