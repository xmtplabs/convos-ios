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
                        .padding(.leading, avatarWidth + DesignConstants.Spacing.step4x)
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
                .padding(.leading, !group.sender.isCurrentUser && !isFullWidthAttachment ? DesignConstants.Spacing.step2x : 0)

                if !message.base.reactions.isEmpty {
                    ReactionIndicatorView(
                        reactions: message.base.reactions,
                        isOutgoing: message.base.sender.isCurrentUser,
                        onTap: { onTapReactions(message) }
                    )
                    .padding(.leading, message.base.sender.isCurrentUser ? 0 : (isFullWidthAttachment ? DesignConstants.Spacing.step2x : avatarWidth + DesignConstants.Spacing.step2x))
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

#Preview("Incoming Messages") {
    ScrollView {
        MessagesGroupView(
            group: .mockIncoming,
            shouldBlurPhotos: false,
            onTapAvatar: { _ in },
            onTapInvite: { _ in },
            onTapReactions: { _ in },
            onReply: { _ in },
            onDoubleTap: { _ in },
            onPhotoRevealed: { _ in },
            onPhotoHidden: { _ in },
            onPhotoDimensionsLoaded: { _, _, _ in }
        )
        .padding()
    }
    .background(.colorBackgroundSurfaceless)
}

#Preview("Outgoing Messages") {
    ScrollView {
        MessagesGroupView(
            group: .mockOutgoing,
            shouldBlurPhotos: false,
            onTapAvatar: { _ in },
            onTapInvite: { _ in },
            onTapReactions: { _ in },
            onReply: { _ in },
            onDoubleTap: { _ in },
            onPhotoRevealed: { _ in },
            onPhotoHidden: { _ in },
            onPhotoDimensionsLoaded: { _, _, _ in }
        )
        .padding()
    }
    .background(.colorBackgroundSurfaceless)
}

#Preview("Mixed Published/Unpublished") {
    ScrollView {
        MessagesGroupView(
            group: .mockMixed,
            shouldBlurPhotos: false,
            onTapAvatar: { _ in },
            onTapInvite: { _ in },
            onTapReactions: { _ in },
            onReply: { _ in },
            onDoubleTap: { _ in },
            onPhotoRevealed: { _ in },
            onPhotoHidden: { _ in },
            onPhotoDimensionsLoaded: { _, _, _ in }
        )
        .padding()
    }
    .background(.colorBackgroundSurfaceless)
}

#Preview("Incoming With Reactions") {
    ScrollView {
        MessagesGroupView(
            group: .mockIncomingWithReactions,
            shouldBlurPhotos: false,
            onTapAvatar: { _ in },
            onTapInvite: { _ in },
            onTapReactions: { _ in },
            onReply: { _ in },
            onDoubleTap: { _ in },
            onPhotoRevealed: { _ in },
            onPhotoHidden: { _ in },
            onPhotoDimensionsLoaded: { _, _, _ in }
        )
        .padding()
    }
    .background(.colorBackgroundSurfaceless)
}

#Preview("Outgoing With Reactions") {
    ScrollView {
        MessagesGroupView(
            group: .mockOutgoingWithReactions,
            shouldBlurPhotos: false,
            onTapAvatar: { _ in },
            onTapInvite: { _ in },
            onTapReactions: { _ in },
            onReply: { _ in },
            onDoubleTap: { _ in },
            onPhotoRevealed: { _ in },
            onPhotoHidden: { _ in },
            onPhotoDimensionsLoaded: { _, _, _ in }
        )
        .padding()
    }
    .background(.colorBackgroundSurfaceless)
}

#Preview("Full Conversation") {
    let alice = ConversationMember.mock(isCurrentUser: false, name: "Alice")
    let me = ConversationMember.mock(isCurrentUser: true)
    let groups: [MessagesGroup] = [
        MessagesGroup(
            id: "conv-1",
            sender: alice,
            messages: [
                .message(Message.mock(text: "Hey! Are you coming to the party tonight?", sender: alice, status: .published), .existing),
                .message(Message.mock(text: "It starts at 8", sender: alice, status: .published), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "conv-2",
            sender: me,
            messages: [
                .message(Message.mock(text: "Yeah I'll be there!", sender: me, status: .published), .existing),
                .message(Message.mock(text: "Should I bring anything?", sender: me, status: .published), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "conv-3",
            sender: alice,
            messages: [
                .message(Message.mock(text: "Just yourself 😊", sender: alice, status: .published), .existing),
            ],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "conv-4",
            sender: me,
            messages: [
                .message(Message.mock(text: "Sounds good, see you then!", sender: me, status: .published), .existing),
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
                    shouldBlurPhotos: false,
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
