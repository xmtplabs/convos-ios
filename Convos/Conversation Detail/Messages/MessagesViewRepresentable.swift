import ConvosCore
import ConvosLogging
import SwiftUI

struct MessagesViewRepresentable: UIViewControllerRepresentable {
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
    let hasAgent: Bool
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
        Log.debug("[Representable] updateUIViewController called, setting onPhotoRevealed and onPhotoHidden")
        messagesViewController.onUserInteraction = onUserInteraction
        messagesViewController.hasBottomBar = hasBottomBar
        messagesViewController.topContentInset = topContentInset
        messagesViewController.bottomBarHeight = bottomBarHeight
        messagesViewController.focusCoordinator = focusCoordinator

        messagesViewController.onTapAvatar = onTapAvatar
        messagesViewController.onLoadPreviousMessages = onLoadPreviousMessages
        messagesViewController.onTapInvite = onTapInvite
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
        messagesViewController.hasAgent = hasAgent
        messagesViewController.isAgentJoinPending = isAgentJoinPending
let menuPresented = contextMenuState.isPresented
        let wasMenuPresented = !messagesViewController.view.isUserInteractionEnabled
        messagesViewController.view.isUserInteractionEnabled = !menuPresented
        if menuPresented {
            messagesViewController.collectionView.panGestureRecognizer.isEnabled = false
            messagesViewController.collectionView.panGestureRecognizer.isEnabled = true
        }
        if wasMenuPresented, !menuPresented {
            messagesViewController.applyDeferredBottomInset()
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
        hasAgent: false,
        isAgentJoinPending: false,
        bottomBarHeight: bottomBarHeight,
        scrollToBottomTrigger: { _ in },
        messageInputFocusTrigger: { _ in }
    )
    .ignoresSafeArea()
}
