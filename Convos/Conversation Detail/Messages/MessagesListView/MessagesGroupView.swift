import ConvosCore
import SwiftUI

struct MessagesGroupView: View {
    let group: MessagesGroup
    let onTapMessage: (AnyMessage) -> Void
    let onTapAvatar: (AnyMessage) -> Void

    @State private var isAppearing: Bool = true

    private var animates: Bool {
        group.messages.first?.origin == .inserted
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            VStack {
                Spacer()

                if !group.sender.isCurrentUser {
                    ProfileAvatarView(profile: group.sender.profile, profileImage: nil, useSystemPlaceholder: false)
                        .frame(width: DesignConstants.ImageSizes.smallAvatar,
                               height: DesignConstants.ImageSizes.smallAvatar)
                        .onTapGesture {
                            if let message = group.messages.last {
                                onTapAvatar(message)
                            }
                        }
                        .hoverEffect(.lift)
                        .scaleEffect(isAppearing ? 0.9 : 1.0)
                        .opacity(isAppearing ? 0.0 : 1.0)
                        .offset(
                            x: isAppearing ? -80 : 0,
                            y: 0.0,
                        )
                        .id("profile-\(group.id)")
                }
            }
            .id("profile-container-\(group.id)")

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                // Render published messages
                let allMessages = group.allMessages
                ForEach(Array(allMessages.enumerated()), id: \.element.base.id) { index, message in
                    if index == 0 && !group.sender.isCurrentUser {
                        // Show sender name for incoming messages
                        Text(group.sender.profile.displayName)
                            .scaleEffect(isAppearing ? 0.9 : 1.0)
                            .opacity(isAppearing ? 0.0 : 1.0)
                            .offset(
                                x: 0.0,
                                y: isAppearing ? 100 : 0,
                            )
                            .blur(radius: isAppearing ? 10.0 : 0.0)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.leading, DesignConstants.Spacing.step2x)
                            .padding(.bottom, DesignConstants.Spacing.stepHalf)
                    }

                    let isLastPublished = message == group.messages.last
                    let isLast = message == group.unpublished.last || isLastPublished
                    let bubbleType: MessageBubbleType = isLast ? .tailed : .normal
                    let showsSentStatus = isLastPublished && group.isLastGroupSentByCurrentUser
                    MessagesGroupItemView(
                        message: message,
                        bubbleType: bubbleType,
                        showsSentStatus: showsSentStatus,
                        onTapMessage: onTapMessage,
                        onTapAvatar: onTapAvatar
                    )
                    .id("messages-group-item-\(message.differenceIdentifier)")
                    .transition(
                        .asymmetric(
                            insertion: .identity,      // no transition on insert
                            removal: .opacity
                        )
                    )
                }
            }
            .id("message-group-container-\(group.id)")
            .transition(
                .asymmetric(
                    insertion: .identity,      // no transition on insert
                    removal: .opacity
                )
            )
        }
        .padding(.vertical, DesignConstants.Spacing.stepX)
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
            onTapMessage: { _ in },
            onTapAvatar: { _ in },
        )
        .padding()
    }
    .background(.colorBackgroundPrimary)
}

#Preview("Outgoing Messages") {
    ScrollView {
        MessagesGroupView(
            group: .mockOutgoing,
            onTapMessage: { _ in },
            onTapAvatar: { _ in },
        )
        .padding()
    }
    .background(.colorBackgroundPrimary)
}

#Preview("Mixed Published/Unpublished") {
    ScrollView {
        MessagesGroupView(
            group: .mockMixed,
            onTapMessage: { _ in },
            onTapAvatar: { _ in },
        )
        .padding()
    }
    .background(.colorBackgroundPrimary)
}
