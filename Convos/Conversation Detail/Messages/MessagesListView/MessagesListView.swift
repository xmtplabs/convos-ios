import ConvosCore
import SwiftUI

struct MessagesListView: View {
    let conversation: Conversation
    @Binding var messages: [MessagesListItemType]
    let invite: Invite
    let focusCoordinator: FocusCoordinator
    let onTapAvatar: (AnyMessage) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onDoubleTap: (AnyMessage) -> Void
    let loadPrevious: () -> Void

    @State private var scrollPosition: ScrollPosition = ScrollPosition(edge: .bottom)
    @State private var lastItemIndex: Int?

    var body: some View {
        ScrollViewReader { _ in
            ScrollView {
                LazyVStack(spacing: 0.0) {
                    // Show invite or conversation info at the top
                    if conversation.creator.isCurrentUser && !conversation.isLocked && !conversation.isFull {
                        InviteView(invite: invite)
                            .id("invite")
                    } else {
                        ConversationInfoPreview(conversation: conversation)
                            .id("conversation-info")
                    }

                    // Render each message list item
                    ForEach(messages.enumerated(), id: \.element.id) { index, item in
                        Group {
                            switch item {
                            case .date(let dateGroup):
                                TextTitleContentView(title: dateGroup.value, profile: nil)
                                    .padding(.vertical, DesignConstants.Spacing.step2x)

                            case .update(_, let update, _):
                                TextTitleContentView(title: update.summary, profile: update.profile)
                                    .padding(.vertical, DesignConstants.Spacing.stepX)

                            case .messages(let group):
                                MessagesGroupView(
                                    group: group,
                                    onTapAvatar: onTapAvatar,
                                    onTapInvite: onTapInvite,
                                    onTapReactions: onTapReactions,
                                    onDoubleTap: onDoubleTap
                                )

                            case .invite(let invite):
                                InviteView(invite: invite)
                                    .padding(.vertical, DesignConstants.Spacing.step2x)

                            case .conversationInfo(let conversation):
                                ConversationInfoPreview(conversation: conversation)
                                    .padding(.vertical, DesignConstants.Spacing.step2x)
                            }
                        }
                        .onScrollVisibilityChange(threshold: 0.1) { isVisible in
//                            if index == messages.count - 1 && isVisible {
//                                loadPrevious()
//                            }
//
                            guard lastItemIndex == nil else { return }

                            if isVisible && index == messages.count - 1 {
                                lastItemIndex = index
                            }
                        }
                    }
                }
            }
            .onChange(of: focusCoordinator.currentFocus) { _, newValue in
                if newValue == .message {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
            .onChange(of: messages) {
                if let last = messages.last {
                    switch last {
                    case .messages(let group):
                        if group.isLastGroupSentByCurrentUser {
                            scrollPosition.scrollTo(edge: .bottom)
                        }
                    default:
                        break
                    }
                }
            }
            .scrollEdgeEffectHidden(for: [.bottom]) // fixes the flickering profile photo
            .animation(.spring(duration: 0.5, bounce: 0.2), value: messages)
            .contentMargins(.horizontal, DesignConstants.Spacing.step4x, for: .scrollContent)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition, anchor: .bottom)
        }
    }
}
