#if canImport(UIKit)
import ConvosCore
import ConvosLogging
import SwiftUI

public struct MessagesViewRepresentable: UIViewControllerRepresentable {
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
    /// can present `MessageDetailView`. Nil for hosts that don't present a
    /// message detail, which suppresses the bubble's "Read more" detail button.
    var onOpenMessageDetail: ((AnyMessage) -> Void)?
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
    var onPresentFileAttachmentPreview: ((HydratedAttachment, URL, ConversationMember, Date) -> Void)?
    var agentBuilderSummaryProvider: ((AgentBuilderCardContent) -> AnyView)?
    var currentUserProfileImage: (() -> UIImage?)?
    var backwardsSecrecyInfoSheet: (() -> AnyView)?
    /// When true the index-0 `.invite` cell renders the full inline
    /// Invite/Scan card (`InviteCodeBody`) for an active hosted session,
    /// instead of the regular inviter QR + menu.
    var showsInviteScanCard: Bool = false
    var inviteScanMode: InviteCodeMode = .inConvo
    var inviteScanInitialSegment: ScanInviteSegment = .invite
    var onScannedInviteCode: ((String) -> Void)?
    var onInviteShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)?
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

    public class Coordinator {
        var scrollToBottomFunction: (() -> Void)?
        var messageInputFocusFunction: (() -> Void)?
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public init(
        conversation: Conversation,
        messages: [MessagesListItemType],
        invite: Invite,
        onUserInteraction: @escaping () -> Void,
        hasLoadedAllMessages: Bool,
        focusCoordinator: FocusCoordinator,
        onTapAvatar: @escaping (ConversationMember) -> Void,
        onLoadPreviousMessages: @escaping () -> Void,
        onTapInvite: @escaping (MessageInvite) -> Void,
        onTapAgentShare: @escaping (MessageAgentShare) -> Void = { _ in },
        agentShareResolver: any AgentShareResolving = MockAgentShareResolver(),
        inviteMembershipResolver: any InviteMembershipResolving = NoopInviteMembershipResolver(),
        onReaction: @escaping (String, String) -> Void,
        onToggleReaction: @escaping (String, String) -> Void,
        onTapReactions: @escaping (AnyMessage) -> Void,
        onTapReadReceipts: @escaping (MessagesGroup) -> Void,
        onTapThinkingIndicator: @escaping (ThinkingSessionDescriptor) -> Void,
        onReply: @escaping (AnyMessage) -> Void,
        onOpenMessageDetail: ((AnyMessage) -> Void)? = nil,
        expandedMessageIds: Set<String> = [],
        onToggleMessageExpanded: @escaping (String) -> Void = { _ in },
        contextMenuState: MessageContextMenuState,
        onPhotoDimensionsLoaded: @escaping (String, Int, Int) -> Void,
        onAgentOutOfCredits: @escaping () -> Void,
        creditsDepleted: Bool,
        onTapUpdateMember: @escaping (ConversationMember) -> Void,
        onTapCapabilityConnect: @escaping (CapabilityConnectPrompt) -> Void = { _ in },
        onRetryMessage: @escaping (AnyMessage) -> Void,
        onDeleteMessage: @escaping (AnyMessage) -> Void,
        onRetryAgentJoin: @escaping () -> Void,
        onCopyInviteLink: @escaping () -> Void,
        onConvoCode: @escaping () -> Void,
        onInviteAgent: @escaping () -> Void,
        onRetryTranscript: @escaping (VoiceMemoTranscriptListItem) -> Void,
        profileSheetForMember: @escaping (ConversationMember) -> AnyView,
        memberContactOverride: @escaping (String) -> Contact?,
        isAgentJoinPending: Bool,
        headerMode: MessagesHeaderMode = .standard,
        agentBuilderSummary: AgentBuilderSummary? = nil,
        agentBuilderTransitionNamespace: Namespace.ID? = nil,
        htmlAttachmentTransitionNamespace: Namespace.ID? = nil,
        onPresentHTMLAttachmentPreview: ((HydratedAttachment, URL, ConversationMember, Date) -> Void)? = nil,
        onPresentFileAttachmentPreview: ((HydratedAttachment, URL, ConversationMember, Date) -> Void)? = nil,
        showsInviteScanCard: Bool = false,
        inviteScanMode: InviteCodeMode = .inConvo,
        inviteScanInitialSegment: ScanInviteSegment = .invite,
        onScannedInviteCode: ((String) -> Void)? = nil,
        onInviteShareCompleted: ((UIActivity.ActivityType?, Bool, Error?) -> Void)? = nil,
        agentBuilderSummaryProvider: ((AgentBuilderCardContent) -> AnyView)? = nil,
        currentUserProfileImage: (() -> UIImage?)? = nil,
        backwardsSecrecyInfoSheet: (() -> AnyView)? = nil,
        bottomBarHeight: CGFloat,
        hasBottomBar: Bool = true,
        topContentInset: CGFloat = 0.0,
        scrollToBottomTrigger: @escaping (@escaping () -> Void) -> Void,
        messageInputFocusTrigger: @escaping (@escaping () -> Void) -> Void
    ) {
        self.conversation = conversation
        self.messages = messages
        self.invite = invite
        self.onUserInteraction = onUserInteraction
        self.hasLoadedAllMessages = hasLoadedAllMessages
        self.focusCoordinator = focusCoordinator
        self.onTapAvatar = onTapAvatar
        self.onLoadPreviousMessages = onLoadPreviousMessages
        self.onTapInvite = onTapInvite
        self.onTapAgentShare = onTapAgentShare
        self.agentShareResolver = agentShareResolver
        self.inviteMembershipResolver = inviteMembershipResolver
        self.onReaction = onReaction
        self.onToggleReaction = onToggleReaction
        self.onTapReactions = onTapReactions
        self.onTapReadReceipts = onTapReadReceipts
        self.onTapThinkingIndicator = onTapThinkingIndicator
        self.onReply = onReply
        self.contextMenuState = contextMenuState
        self.onPhotoDimensionsLoaded = onPhotoDimensionsLoaded
        self.onAgentOutOfCredits = onAgentOutOfCredits
        self.creditsDepleted = creditsDepleted
        self.onTapUpdateMember = onTapUpdateMember
        self.onTapCapabilityConnect = onTapCapabilityConnect
        self.onRetryMessage = onRetryMessage
        self.onDeleteMessage = onDeleteMessage
        self.onRetryAgentJoin = onRetryAgentJoin
        self.onCopyInviteLink = onCopyInviteLink
        self.onConvoCode = onConvoCode
        self.onInviteAgent = onInviteAgent
        self.onRetryTranscript = onRetryTranscript
        self.profileSheetForMember = profileSheetForMember
        self.memberContactOverride = memberContactOverride
        self.isAgentJoinPending = isAgentJoinPending
        self.headerMode = headerMode
        self.agentBuilderSummary = agentBuilderSummary
        self.agentBuilderTransitionNamespace = agentBuilderTransitionNamespace
        self.htmlAttachmentTransitionNamespace = htmlAttachmentTransitionNamespace
        self.onPresentHTMLAttachmentPreview = onPresentHTMLAttachmentPreview
        self.onPresentFileAttachmentPreview = onPresentFileAttachmentPreview
        self.onOpenMessageDetail = onOpenMessageDetail
        self.expandedMessageIds = expandedMessageIds
        self.onToggleMessageExpanded = onToggleMessageExpanded
        self.showsInviteScanCard = showsInviteScanCard
        self.inviteScanMode = inviteScanMode
        self.inviteScanInitialSegment = inviteScanInitialSegment
        self.onScannedInviteCode = onScannedInviteCode
        self.onInviteShareCompleted = onInviteShareCompleted
        self.agentBuilderSummaryProvider = agentBuilderSummaryProvider
        self.currentUserProfileImage = currentUserProfileImage
        self.backwardsSecrecyInfoSheet = backwardsSecrecyInfoSheet
        self.bottomBarHeight = bottomBarHeight
        self.hasBottomBar = hasBottomBar
        self.topContentInset = topContentInset
        self.scrollToBottomTrigger = scrollToBottomTrigger
        self.messageInputFocusTrigger = messageInputFocusTrigger
    }

    public func makeUIViewController(context: Context) -> MessagesViewController {
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

    public func updateUIViewController(_ messagesViewController: MessagesViewController, context: Context) {
        Log.debug("[Representable] updateUIViewController called, setting onPhotoRevealed and onPhotoHidden")
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
        messagesViewController.agentBuilderSummaryProvider = agentBuilderSummaryProvider
        messagesViewController.currentUserProfileImage = currentUserProfileImage
        messagesViewController.backwardsSecrecyInfoSheet = backwardsSecrecyInfoSheet
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
        messagesViewController.onPresentFileAttachmentPreview = onPresentFileAttachmentPreview
        messagesViewController.showsInviteScanCard = showsInviteScanCard
        messagesViewController.inviteScanMode = inviteScanMode
        messagesViewController.inviteScanInitialSegment = inviteScanInitialSegment
        messagesViewController.onScannedInviteCode = onScannedInviteCode
        messagesViewController.onInviteShareCompleted = onInviteShareCompleted
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

#endif
