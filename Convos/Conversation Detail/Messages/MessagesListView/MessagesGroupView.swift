import ConvosCore
import SwiftUI

struct MessagesGroupView: View {
    let group: MessagesGroup
    let onTapAvatar: (AnyMessage) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onDoubleTap: (AnyMessage) -> Void
    let onReply: (AnyMessage) -> Void

    @State private var isAppearing: Bool = true

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
                if index == 0 && !group.sender.isCurrentUser && !isReply {
                    Text(group.sender.profile.displayName)
                        .scaleEffect(isAppearing ? 0.9 : 1.0)
                        .opacity(isAppearing ? 0.0 : 1.0)
                        .offset(
                            x: 0.0,
                            y: isAppearing ? 100 : 0
                        )
                        .blur(radius: isAppearing ? 10.0 : 0.0)
                        .font(.caption)
                        .foregroundColor(.colorTextSecondary)
                        .padding(.leading, avatarWidth + DesignConstants.Spacing.step3x)
                }

                let lastMessage = group.unpublished.last ?? group.messages.last
                let isLast = message == lastMessage
                let bubbleType: MessageBubbleType = isLast ? .tailed : .normal
                let isLastPublished = message == group.messages.last
                let showsSentStatus = isLastPublished && group.isLastGroupSentByCurrentUser

                HStack(alignment: .bottom, spacing: avatarSpacing) {
                    if !group.sender.isCurrentUser {
                        Color.clear
                            .frame(width: avatarSize, height: avatarSize)
                    }

                    MessagesGroupItemView(
                        message: message,
                        bubbleType: bubbleType,
                        onTapAvatar: onTapAvatar,
                        onTapInvite: onTapInvite,
                        onDoubleTap: onDoubleTap,
                        onReply: onReply
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
                        }
                    }
                }

                if !message.base.reactions.isEmpty {
                    ReactionIndicatorView(
                        reactions: message.base.reactions,
                        isOutgoing: message.base.sender.isCurrentUser,
                        onTap: { onTapReactions(message) }
                    )
                    .padding(.leading, message.base.sender.isCurrentUser ? 0 : avatarWidth)
                    .padding(.bottom, DesignConstants.Spacing.stepX)
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
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .zIndex(60)
                    .id("sent-status-\(message.differenceIdentifier)")
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
        .id("messages-group-\(group.id)")
    }
}

#Preview("Incoming Messages") {
    ScrollView {
        MessagesGroupView(
            group: .mockIncoming,
            onTapAvatar: { _ in },
            onTapInvite: { _ in },
            onTapReactions: { _ in },
            onDoubleTap: { _ in },
            onReply: { _ in }
        )
        .padding()
    }
    .background(.colorBackgroundSurfaceless)
}

#Preview("Outgoing Messages") {
    ScrollView {
        MessagesGroupView(
            group: .mockOutgoing,
            onTapAvatar: { _ in },
            onTapInvite: { _ in },
            onTapReactions: { _ in },
            onDoubleTap: { _ in },
            onReply: { _ in }
        )
        .padding()
    }
    .background(.colorBackgroundSurfaceless)
}

#Preview("Mixed Published/Unpublished") {
    ScrollView {
        MessagesGroupView(
            group: .mockMixed,
            onTapAvatar: { _ in },
            onTapInvite: { _ in },
            onTapReactions: { _ in },
            onDoubleTap: { _ in },
            onReply: { _ in }
        )
        .padding()
    }
    .background(.colorBackgroundSurfaceless)
}

#Preview("Incoming With Reactions") {
    ScrollView {
        MessagesGroupView(
            group: .mockIncomingWithReactions,
            onTapAvatar: { _ in },
            onTapInvite: { _ in },
            onTapReactions: { _ in },
            onDoubleTap: { _ in },
            onReply: { _ in }
        )
        .padding()
    }
    .background(.colorBackgroundSurfaceless)
}

#Preview("Outgoing With Reactions") {
    ScrollView {
        MessagesGroupView(
            group: .mockOutgoingWithReactions,
            onTapAvatar: { _ in },
            onTapInvite: { _ in },
            onTapReactions: { _ in },
            onDoubleTap: { _ in },
            onReply: { _ in }
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
            unpublished: [],
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
            unpublished: [],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "conv-3",
            sender: alice,
            messages: [
                .message(Message.mock(text: "Just yourself 😊", sender: alice, status: .published), .existing),
            ],
            unpublished: [],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        ),
        MessagesGroup(
            id: "conv-4",
            sender: me,
            messages: [
                .message(Message.mock(text: "Sounds good, see you then!", sender: me, status: .published), .existing),
            ],
            unpublished: [],
            isLastGroup: true,
            isLastGroupSentByCurrentUser: true
        ),
    ]

    ScrollView {
        VStack(spacing: 0) {
            ForEach(groups) { group in
                MessagesGroupView(
                    group: group,
                    onTapAvatar: { _ in },
                    onTapInvite: { _ in },
                    onTapReactions: { _ in },
                    onDoubleTap: { _ in },
                    onReply: { _ in }
                )
            }
        }
    }
    .background(.colorBackgroundPrimary)
}
