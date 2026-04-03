import ConvosCore
import SwiftUI

struct MessagesListView: View {
    let conversation: Conversation
    @Binding var messages: [MessagesListItemType]
    let invite: Invite
    let focusCoordinator: FocusCoordinator
    let shouldBlurPhotos: Bool
    let onTapAvatar: (AnyMessage) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onReply: (AnyMessage) -> Void
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let onTapUpdateMember: (ConversationMember) -> Void
    let onAgentOutOfCredits: () -> Void
    let onRetryAssistantJoin: () -> Void
    let onCopyInviteLink: () -> Void
    let onConvoCode: () -> Void
    let onInviteAssistant: () -> Void
    let hasAssistant: Bool
    let isAssistantJoinPending: Bool
    let isAssistantEnabled: Bool
    let loadPrevious: () -> Void

    @State private var scrollPosition: ScrollPosition = ScrollPosition(edge: .bottom)
    @State private var lastItemIndex: Int?

    var body: some View {
        ScrollViewReader { _ in
            ScrollView {
                LazyVStack(spacing: 0.0) {
                    // Show invite or conversation info at the top
                    if conversation.creator.isCurrentUser && !conversation.isLocked && !conversation.isFull {
                        VStack(spacing: DesignConstants.Spacing.step4x) {
                            InviteView(invite: invite)
                            NewConvoIdentityView(
                                onCopyLink: onCopyInviteLink,
                                onConvoCode: onConvoCode,
                                onInviteAssistant: onInviteAssistant,
                                hasAssistant: hasAssistant,
                                isAssistantJoinPending: isAssistantJoinPending,
                                isAssistantEnabled: isAssistantEnabled
                            )
                        }
                        .id("invite")
                    } else {
                        VStack(spacing: DesignConstants.Spacing.step4x) {
                            ConversationInfoPreview(conversation: conversation)
                        }
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
                                VStack(spacing: 0) {
                                    TextTitleContentView(
                                        title: update.summary,
                                        profile: update.profile,
                                        agentVerification: update.profileMember?.agentVerification ?? .unverified,
                                        onTap: update.profileMember.map { member in
                                            { onTapUpdateMember(member) }
                                        }
                                    )
                                        .padding(.vertical, DesignConstants.Spacing.stepX)
                                    if update.addedAgent {
                                        AssistantJoinedInfoView()
                                    }
                                }

                            case .messages(let group):
                                MessagesGroupView(
                                    group: group,
                                    shouldBlurPhotos: shouldBlurPhotos,
                                    onTapAvatar: onTapAvatar,
                                    onTapInvite: onTapInvite,
                                    onTapReactions: onTapReactions,
                                    onReply: onReply,
                                    onPhotoRevealed: onPhotoRevealed,
                                    onPhotoHidden: onPhotoHidden,
                                    onPhotoDimensionsLoaded: onPhotoDimensionsLoaded
                                )

                            case .invite(let invite):
                                InviteView(invite: invite)
                                    .padding(.vertical, DesignConstants.Spacing.step2x)

                            case .conversationInfo(let conversation):
                                ConversationInfoPreview(conversation: conversation)
                                    .padding(.vertical, DesignConstants.Spacing.step2x)

                            case .agentOutOfCredits(let profile):
                                TextTitleContentView(
                                    title: "\(profile.displayName) is out of processing power",
                                    profile: profile,
                                    onTap: onAgentOutOfCredits
                                )
                                .padding(.vertical, DesignConstants.Spacing.step2x)

                            case let .assistantJoinStatus(status, requesterName, _):
                                AssistantJoinStatusView(
                                    status: status,
                                    requesterName: requesterName,
                                    onRetry: onRetryAssistantJoin
                                )
                                .padding(.vertical, DesignConstants.Spacing.step2x)

                            case let .assistantPresentInfo(agent, inviterName):
                                let title = inviterName.map { "Assistant is present · Invited by \($0)" } ?? "Assistant is present"
                                VStack(spacing: 0) {
                                    TextTitleContentView(
                                        title: title,
                                        profile: agent.profile,
                                        agentVerification: agent.agentVerification
                                    )
                                        .padding(.vertical, DesignConstants.Spacing.step4x)
                                        .padding(.horizontal, DesignConstants.Spacing.step4x)
                                    AssistantJoinedInfoView()
                                        .padding(.horizontal, DesignConstants.Spacing.step4x)
                                }
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
            .scrollEdgeEffectHidden(for: [.bottom]) // fixes the flickering profile photo
            .animation(.spring(duration: 0.5, bounce: 0.2), value: messages)
            .contentMargins(.horizontal, DesignConstants.Spacing.step4x, for: .scrollContent)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition, anchor: .bottom)
        }
    }
}
