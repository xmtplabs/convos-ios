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
    let shouldBlurPhotos: Bool
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
    let contextMenuState: MessageContextMenuState
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let onAgentOutOfCredits: () -> Void
    let creditsDepleted: Bool
    let onTapUpdateMember: (ConversationMember) -> Void
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
    var agentBuilderSummaryProvider: ((AgentBuilderCardContent, Namespace.ID?) -> AnyView)?
    var currentUserProfileImage: (() -> UIImage?)?
    var backwardsSecrecyInfoSheet: (() -> AnyView)?
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
        shouldBlurPhotos: Bool,
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
        contextMenuState: MessageContextMenuState,
        onPhotoRevealed: @escaping (String) -> Void,
        onPhotoHidden: @escaping (String) -> Void,
        onPhotoDimensionsLoaded: @escaping (String, Int, Int) -> Void,
        onAgentOutOfCredits: @escaping () -> Void,
        creditsDepleted: Bool,
        onTapUpdateMember: @escaping (ConversationMember) -> Void,
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
        agentBuilderSummaryProvider: ((AgentBuilderCardContent, Namespace.ID?) -> AnyView)? = nil,
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
        self.shouldBlurPhotos = shouldBlurPhotos
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
        self.onPhotoRevealed = onPhotoRevealed
        self.onPhotoHidden = onPhotoHidden
        self.onPhotoDimensionsLoaded = onPhotoDimensionsLoaded
        self.onAgentOutOfCredits = onAgentOutOfCredits
        self.creditsDepleted = creditsDepleted
        self.onTapUpdateMember = onTapUpdateMember
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
        messagesViewController.shouldBlurPhotos = shouldBlurPhotos
        messagesViewController.onPhotoRevealed = { key in
            Log.debug("[Representable] onPhotoRevealed wrapper called with key: \(key.prefix(50))...")
            self.onPhotoRevealed(key)
        }
        messagesViewController.onPhotoHidden = { key in
            Log.debug("[Representable] onPhotoHidden wrapper called with key: \(key.prefix(50))...")
            self.onPhotoHidden(key)
        }
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
        shouldBlurPhotos: true,
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
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
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
#endif
