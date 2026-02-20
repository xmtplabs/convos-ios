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
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let bottomBarHeight: CGFloat
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
        context.coordinator.scrollToBottomFunction = { [weak viewController] in
            viewController?.scrollToBottomForSend()
        }
        scrollToBottomTrigger { context.coordinator.scrollToBottomFunction?() }
        return viewController
    }

    func updateUIViewController(_ messagesViewController: MessagesViewController, context: Context) {
        Log.info("[Representable] updateUIViewController called, setting onPhotoRevealed and onPhotoHidden")
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
            Log.info("[Representable] onPhotoRevealed wrapper called with key: \(key.prefix(50))...")
            self.onPhotoRevealed(key)
        }
        messagesViewController.onPhotoHidden = { key in
            Log.info("[Representable] onPhotoHidden wrapper called with key: \(key.prefix(50))...")
            self.onPhotoHidden(key)
        }
        messagesViewController.onPhotoDimensionsLoaded = { key, width, height in
            self.onPhotoDimensionsLoaded(key, width, height)
        }
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
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in },
        bottomBarHeight: bottomBarHeight,
        scrollToBottomTrigger: { _ in }
    )
    .ignoresSafeArea()
}
