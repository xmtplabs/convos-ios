import ConvosCore
import ConvosLogging
import SwiftUI

struct MessagesViewRepresentable: UIViewControllerRepresentable {
    let conversation: Conversation
    let messages: [MessagesListItemType]
    let invite: Invite
    let onUserInteraction: () -> Void
    let hasLoadedAllMessages: Bool
    let focusCoordinator: FocusCoordinator
    let onTapAvatar: (ConversationMember) -> Void
    let onLoadPreviousMessages: () -> Void
    let onTapInvite: (MessageInvite) -> Void
    var onTapAgentShare: (MessageAgentShare) -> Void = { _ in }
    var agentShareResolver: any AgentShareResolving = MockAgentShareResolver()
    var inviteMembershipResolver: any InviteMembershipResolving = NoopInviteMembershipResolver()
    let onReaction: (String, String) -> Void
    let onToggleReaction: (String, String) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onTapReadReceipts: (MessagesGroup) -> Void
    let onTapThinkingIndicator: (ThinkingSessionDescriptor) -> Void
    let onReply: (AnyMessage) -> Void
    /// Surfaces a pathological text bubble's "Read More" tap to the host so it
    /// can present `MessageDetailView`. Default no-op for hosts (the thinking
    /// detail sheet) that don't present a message detail.
    var onOpenMessageDetail: (AnyMessage) -> Void = { _ in }
    /// Message ids with long-body inline expansion on (owned by the VM so it
    /// survives cell reuse). Default empty for hosts that never expand.
    var expandedMessageIds: Set<String> = []
    /// Toggles a message id's long-body inline expansion on the host.
    var onToggleMessageExpanded: (String) -> Void = { _ in }
    let contextMenuState: MessageContextMenuState
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let onAgentOutOfCredits: () -> Void
    let creditsDepleted: Bool
    let onTapUpdateMember: (ConversationMember) -> Void
    var onTapCapabilityConnect: (CapabilityConnectPrompt) -> Void = { _ in }
    let onRetryMessage: (AnyMessage) -> Void
    let onDeleteMessage: (AnyMessage) -> Void
    let onRetryAgentJoin: () -> Void
    let onCopyInviteLink: () -> Void
    let onConvoCode: () -> Void
    let onInviteAgent: () -> Void
    let onRetryTranscript: (VoiceMemoTranscriptListItem) -> Void
    let profileSheetForMember: (ConversationMember) -> AnyView
    let memberContactOverride: (String) -> Contact?
    let isAgentJoinPending: Bool
    var headerMode: MessagesHeaderMode = .standard
    var agentBuilderSummary: AgentBuilderSummary?
    var agentBuilderTransitionNamespace: Namespace.ID?
    var htmlAttachmentTransitionNamespace: Namespace.ID?
    var onPresentHTMLAttachmentPreview: ((HydratedAttachment, URL, ConversationMember, Date) -> Void)?
    let bottomBarHeight: CGFloat
    /// Hosts that intentionally have no composer (the thinking detail sheet)
    /// pass `false` so the controller doesn't wait for a non-existent bottom
    /// bar measurement before applying its initial state.
    var hasBottomBar: Bool = true
    /// Top inset (in points) added to the controller's safe area for hosts
    /// that float a bar over the collection view. See
    /// `MessagesViewController.topContentInset`. Default 0 keeps the chat
    /// path on its existing layout.
    var topContentInset: CGFloat = 0.0
    let scrollToBottomTrigger: (@escaping () -> Void) -> Void
    let messageInputFocusTrigger: (@escaping () -> Void) -> Void

    class Coordinator {
        var scrollToBottomFunction: (() -> Void)?
        var messageInputFocusFunction: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> MessagesViewController {
        let viewController = MessagesViewController()
        viewController.contextMenuState = contextMenuState
        context.coordinator.scrollToBottomFunction = { [weak viewController] in
            viewController?.scrollToBottomForSend()
        }
        context.coordinator.messageInputFocusFunction = { [weak viewController] in
            viewController?.messageInputDidBecomeFocused()
        }
        scrollToBottomTrigger { context.coordinator.scrollToBottomFunction?() }
        messageInputFocusTrigger { context.coordinator.messageInputFocusFunction?() }
        return viewController
    }

    func updateUIViewController(_ messagesViewController: MessagesViewController, context: Context) {
        messagesViewController.onUserInteraction = onUserInteraction
        messagesViewController.hasBottomBar = hasBottomBar
        messagesViewController.topContentInset = topContentInset
        // Assign bottomBarHeight before state: its deferred inset update must be
        // enqueued ahead of the initial load's scroll-to-bottom completion.
        messagesViewController.bottomBarHeight = bottomBarHeight
        messagesViewController.focusCoordinator = focusCoordinator

        messagesViewController.onTapAvatar = onTapAvatar
        messagesViewController.onLoadPreviousMessages = onLoadPreviousMessages
        messagesViewController.onTapInvite = onTapInvite
        messagesViewController.onTapAgentShare = onTapAgentShare
        messagesViewController.agentShareResolver = agentShareResolver
        messagesViewController.inviteMembershipResolver = inviteMembershipResolver
        messagesViewController.onReaction = onReaction
        messagesViewController.onToggleReaction = onToggleReaction
        messagesViewController.onTapReactions = onTapReactions
        messagesViewController.onTapReadReceipts = onTapReadReceipts
        messagesViewController.onTapThinkingIndicator = onTapThinkingIndicator
        messagesViewController.onReply = onReply
        messagesViewController.onOpenMessageDetail = onOpenMessageDetail
        messagesViewController.onToggleMessageExpanded = onToggleMessageExpanded
        messagesViewController.expandedMessageIds = expandedMessageIds
        messagesViewController.onPhotoDimensionsLoaded = { key, width, height in
            self.onPhotoDimensionsLoaded(key, width, height)
        }
        messagesViewController.onAgentOutOfCredits = onAgentOutOfCredits
        messagesViewController.creditsDepleted = creditsDepleted
        messagesViewController.onTapUpdateMember = { member in
            self.onTapUpdateMember(member)
        }
        messagesViewController.onTapCapabilityConnect = { prompt in
            self.onTapCapabilityConnect(prompt)
        }
        messagesViewController.onRetryMessage = { message in
            self.onRetryMessage(message)
        }
        messagesViewController.onDeleteMessage = { message in
            self.onDeleteMessage(message)
        }
        messagesViewController.onRetryAgentJoin = onRetryAgentJoin
        messagesViewController.onCopyInviteLink = onCopyInviteLink
        messagesViewController.onConvoCode = onConvoCode
        messagesViewController.onInviteAgent = onInviteAgent
        messagesViewController.onRetryTranscript = onRetryTranscript
        messagesViewController.profileSheetForMember = profileSheetForMember
        messagesViewController.memberContactOverride = memberContactOverride
        messagesViewController.isAgentJoinPending = isAgentJoinPending
let menuPresented = contextMenuState.isPresented
        let wasMenuPresented = !messagesViewController.view.isUserInteractionEnabled
        messagesViewController.view.isUserInteractionEnabled = !menuPresented
        if menuPresented {
            messagesViewController.collectionView.panGestureRecognizer.isEnabled = false
            messagesViewController.collectionView.panGestureRecognizer.isEnabled = true
        }
        if wasMenuPresented, !menuPresented {
            messagesViewController.restoreBottomInsetAfterContextMenu()
        }
        messagesViewController.onPresentHTMLAttachmentPreview = onPresentHTMLAttachmentPreview
        messagesViewController.state = .init(
            conversation: conversation,
            messages: messages,
            invite: invite,
            hasLoadedAllMessages: hasLoadedAllMessages,
            headerMode: headerMode,
            agentBuilderSummary: agentBuilderSummary,
            agentBuilderTransitionNamespace: agentBuilderTransitionNamespace,
            htmlAttachmentTransitionNamespace: htmlAttachmentTransitionNamespace
        )
    }
}

#Preview {
    @Previewable @State var bottomBarHeight: CGFloat = 0.0
    let messages: [MessagesListItemType] = []
    let invite: Invite = .empty

    MessagesViewRepresentable(
        conversation: .mock(),
        messages: messages,
        invite: invite,
        onUserInteraction: {},
        hasLoadedAllMessages: false,
        focusCoordinator: FocusCoordinator(horizontalSizeClass: nil),
        onTapAvatar: { _ in },
        onLoadPreviousMessages: {},
        onTapInvite: { _ in },
        onReaction: { _, _ in },
        onToggleReaction: { _, _ in },
        onTapReactions: { _ in },
        onTapReadReceipts: { _ in },
        onTapThinkingIndicator: { _ in },
        onReply: { _ in },
        contextMenuState: .init(),
        onPhotoDimensionsLoaded: { _, _, _ in },
        onAgentOutOfCredits: {},
        creditsDepleted: false,
        onTapUpdateMember: { _ in },
        onRetryMessage: { _ in },
        onDeleteMessage: { _ in },
        onRetryAgentJoin: {},
        onCopyInviteLink: {},
        onConvoCode: {},
        onInviteAgent: {},
        onRetryTranscript: { _ in },
        profileSheetForMember: { _ in AnyView(EmptyView()) },
        memberContactOverride: { _ in nil },
        isAgentJoinPending: false,
        bottomBarHeight: bottomBarHeight,
        scrollToBottomTrigger: { _ in },
        messageInputFocusTrigger: { _ in }
    )
    .ignoresSafeArea()
}
