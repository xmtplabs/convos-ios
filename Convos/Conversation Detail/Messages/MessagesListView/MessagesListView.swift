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
    let onTapReadReceipts: (MessagesGroup) -> Void
    let onTapThinkingIndicator: (ThinkingSessionDescriptor) -> Void
    let onReaction: (String, String) -> Void
    let onToggleReaction: (String, String) -> Void
    let onReply: (AnyMessage) -> Void
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let onTapUpdateMember: (ConversationMember) -> Void
    let onAgentOutOfCredits: () -> Void
    let onRetryAgentJoin: () -> Void
    let onCopyInviteLink: () -> Void
    let onConvoCode: () -> Void
    let onInviteAgent: () -> Void
    let allVoiceMemoTranscripts: [String: VoiceMemoTranscriptListItem]
    let hasAgent: Bool
    let isAgentJoinPending: Bool
    let loadPrevious: () -> Void

    @State private var scrollPosition: ScrollPosition = ScrollPosition(edge: .bottom)
    @State private var lastItemIndex: Int?

var body: some View {
        ScrollViewReader { _ in
            ScrollView {
                LazyVStack(spacing: 0.0) {
                    headerView
                    messagesList
                }
            }
            .scrollEdgeEffectHidden(for: [.bottom])
            .animation(.spring(duration: 0.5, bounce: 0.2), value: messages)
            .contentMargins(.horizontal, DesignConstants.Spacing.step4x, for: .scrollContent)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition, anchor: .bottom)
        }
    }

    @ViewBuilder
    private var headerView: some View {
        if conversation.creator.isCurrentUser && !conversation.isLocked && !conversation.isFull {
            VStack(spacing: DesignConstants.Spacing.step4x) {
                InviteView(invite: invite)
                NewConvoIdentityView(
                    onCopyLink: onCopyInviteLink,
                    onConvoCode: onConvoCode,
                    onInviteAgent: onInviteAgent,
                    hasAgent: hasAgent,
                    isAgentJoinPending: isAgentJoinPending
                )
            }
            .id("invite")
        } else {
            VStack(spacing: DesignConstants.Spacing.step4x) {
                ConversationInfoPreview(conversation: conversation)
            }
            .id("conversation-info")
        }
    }

    // Concrete tuple-array (not a lazy `EnumeratedSequence`) so the `ForEach`
    // below works on a `RandomAccessCollection` with a fully-resolved element
    // type, keeping its getter's type-check time well under the limit.
    private var enumeratedMessages: [(offset: Int, element: MessagesListItemType)] {
        Array(messages.enumerated())
    }

    private var messagesList: some View {
        ForEach(enumeratedMessages, id: \.element.id) { entry in
            itemView(for: entry.element)
                .onScrollVisibilityChange(threshold: 0.1) { isVisible in
                    handleScrollVisibilityChange(isVisible: isVisible, index: entry.offset)
                }
        }
    }

    private func handleScrollVisibilityChange(isVisible: Bool, index: Int) {
        guard lastItemIndex == nil else { return }
        if isVisible, index == messages.count - 1 {
            lastItemIndex = index
        }
    }

    @ViewBuilder
    private func itemView(for item: MessagesListItemType) -> some View {
        switch item {
        case .date(let dateGroup):
            TextTitleContentView(title: dateGroup.value, profile: nil)
                .padding(.vertical, DesignConstants.Spacing.step2x)

        case .update(_, let update, _):
            updateView(for: update)

        case .messages(let group):
            messagesGroupView(for: group)

        case .invite(let invite):
            InviteView(invite: invite)
                .padding(.vertical, DesignConstants.Spacing.step2x)

        case .conversationInfo(let conversation):
            ConversationInfoPreview(conversation: conversation)
                .padding(.vertical, DesignConstants.Spacing.step2x)

        case let .agentOutOfCredits(member, isCurrentUserCreator):
            AgentLostPowerStatus(
                agentName: member.profile.displayName,
                isCreator: isCurrentUserCreator,
                onUpgrade: onAgentOutOfCredits
            )
            .padding(.vertical, DesignConstants.Spacing.step2x)

        case let .agentJoinStatus(status, requesterName, _):
            AgentJoinStatusView(
                status: status,
                requesterName: requesterName,
                onRetry: onRetryAgentJoin
            )
            .padding(.vertical, DesignConstants.Spacing.step2x)

        case let .agentPresentInfo(agent, inviterName):
            agentPresentView(agent: agent, inviterName: inviterName)

        case let .connectionEvent(_, summary, _):
            ConnectionEventSummaryView(summary: summary)
                .padding(.vertical, DesignConstants.Spacing.step2x)

        case .agentBuilderSummary(let content):
            AgentBuilderSummaryView(content: content)
                .padding(.vertical, DesignConstants.Spacing.step2x)

        case .typingIndicator:
            EmptyView()
        }
    }

    @ViewBuilder
    private func updateView(for update: ConversationUpdate) -> some View {
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
            if update.addedVerifiedAgent {
                AgentJoinedInfoView()
            }
        }
    }

    @ViewBuilder
    private func agentPresentView(agent: ConversationMember, inviterName: String?) -> some View {
        let isVerified = agent.agentVerification.isVerified
        let label = isVerified ? "Agent" : "Agent"
        let title = inviterName.map { "\(label) is present · Invited by \($0)" } ?? "\(label) is present"
        VStack(spacing: 0) {
            TextTitleContentView(
                title: title,
                profile: agent.profile,
                agentVerification: agent.agentVerification
            )
            .padding(.vertical, DesignConstants.Spacing.step4x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            if isVerified {
                AgentJoinedInfoView()
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
            }
        }
    }

    private func messagesGroupView(for group: MessagesGroup) -> MessagesGroupView {
        return MessagesGroupView(
            group: group,
            conversationId: conversation.id,
            shouldBlurPhotos: shouldBlurPhotos,
            onTapAvatar: onTapAvatar,
            onTapInvite: onTapInvite,
            onTapReactions: onTapReactions,
            onTapReadReceipts: onTapReadReceipts,
            onTapThinkingIndicator: onTapThinkingIndicator,
            onReaction: onReaction,
            onToggleReaction: onToggleReaction,
            onReply: onReply,
            onPhotoRevealed: onPhotoRevealed,
            onPhotoHidden: onPhotoHidden,
            onPhotoDimensionsLoaded: onPhotoDimensionsLoaded,
            allVoiceMemoTranscripts: allVoiceMemoTranscripts
        )
    }
}
