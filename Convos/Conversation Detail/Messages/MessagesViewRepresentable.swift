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
    let onTapReactions: (AnyMessage) -> Void
    let onReply: (AnyMessage) -> Void
    let contextMenuState: MessageContextMenuState
    let mediaZoomState: MediaZoomState
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let onAgentOutOfCredits: () -> Void
    let onTapUpdateMember: (ConversationMember) -> Void
    let onRetryMessage: (AnyMessage) -> Void
    let onDeleteMessage: (AnyMessage) -> Void
    let onRetryAssistantJoin: () -> Void
    let onCopyInviteLink: () -> Void
    let onConvoCode: () -> Void
    let onInviteAssistant: () -> Void
    let onRetryTranscript: (VoiceMemoTranscriptListItem) -> Void
    let hasAssistant: Bool
    let isAssistantJoinPending: Bool
    let isAssistantEnabled: Bool
    let bottomBarHeight: CGFloat
    let onBottomOverscrollChanged: (CGFloat) -> Void
    let onBottomOverscrollReleased: (CGFloat) -> Void
    let scrollToBottomTrigger: (@escaping () -> Void) -> Void

    class Coordinator {
        var scrollToBottomFunction: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> MessagesViewController {
        let viewController = MessagesViewController()
        viewController.contextMenuState = contextMenuState
        viewController.mediaZoomState = mediaZoomState
        context.coordinator.scrollToBottomFunction = { [weak viewController] in
            viewController?.scrollToBottomForSend()
        }
        scrollToBottomTrigger { context.coordinator.scrollToBottomFunction?() }
        return viewController
    }

    func updateUIViewController(_ messagesViewController: MessagesViewController, context: Context) {
        Log.debug("[Representable] updateUIViewController called, setting onPhotoRevealed and onPhotoHidden")
        messagesViewController.onUserInteraction = onUserInteraction
        messagesViewController.bottomBarHeight = bottomBarHeight
        messagesViewController.focusCoordinator = focusCoordinator

        messagesViewController.onTapAvatar = onTapAvatar
        messagesViewController.onLoadPreviousMessages = onLoadPreviousMessages
        messagesViewController.onTapInvite = onTapInvite
        messagesViewController.onReaction = onReaction
        messagesViewController.onTapReactions = onTapReactions
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
        messagesViewController.onBottomOverscrollChanged = onBottomOverscrollChanged
        messagesViewController.onBottomOverscrollReleased = onBottomOverscrollReleased
        messagesViewController.onPhotoDimensionsLoaded = { key, width, height in
            self.onPhotoDimensionsLoaded(key, width, height)
        }
        messagesViewController.onAgentOutOfCredits = onAgentOutOfCredits
        messagesViewController.onTapUpdateMember = { member in
            self.onTapUpdateMember(member)
        }
        messagesViewController.onRetryMessage = { message in
            self.onRetryMessage(message)
        }
        messagesViewController.onDeleteMessage = { message in
            self.onDeleteMessage(message)
        }
        messagesViewController.onRetryAssistantJoin = onRetryAssistantJoin
        messagesViewController.onCopyInviteLink = onCopyInviteLink
        messagesViewController.onConvoCode = onConvoCode
        messagesViewController.onInviteAssistant = onInviteAssistant
        messagesViewController.onRetryTranscript = onRetryTranscript
        messagesViewController.hasAssistant = hasAssistant
        messagesViewController.isAssistantJoinPending = isAssistantJoinPending
        messagesViewController.isAssistantEnabled = isAssistantEnabled
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
        messagesViewController.state = .init(
            conversation: conversation,
            messages: messages,
            invite: invite,
            hasLoadedAllMessages: hasLoadedAllMessages
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
        onTapReactions: { _ in },
        onReply: { _ in },
        contextMenuState: .init(),
        mediaZoomState: .init(),
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in },
        onAgentOutOfCredits: {},
        onTapUpdateMember: { _ in },
        onRetryMessage: { _ in },
        onDeleteMessage: { _ in },
        onRetryAssistantJoin: {},
        onCopyInviteLink: {},
        onConvoCode: {},
        onInviteAssistant: {},
        onRetryTranscript: { _ in },
        hasAssistant: false,
        isAssistantJoinPending: false,
        isAssistantEnabled: true,
        bottomBarHeight: bottomBarHeight,
        onBottomOverscrollChanged: { _ in },
        onBottomOverscrollReleased: { _ in },
        scrollToBottomTrigger: { _ in }
    )
    .ignoresSafeArea()
}
