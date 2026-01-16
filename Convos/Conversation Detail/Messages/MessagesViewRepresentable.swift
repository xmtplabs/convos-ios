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
    let onTapAvatar: (ConversationMember) -> Void
    let onLoadPreviousMessages: () -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onReaction: (String, String) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onDoubleTap: (AnyMessage) -> Void
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let bottomBarHeight: CGFloat

    func makeUIViewController(context: Context) -> MessagesViewController {
        return MessagesViewController()
    }

    func updateUIViewController(_ messagesViewController: MessagesViewController, context: Context) {
        Log.info("[Representable] updateUIViewController called, setting onPhotoRevealed and onPhotoHidden")
        messagesViewController.onUserInteraction = onUserInteraction
        messagesViewController.bottomBarHeight = bottomBarHeight
        messagesViewController.onTapAvatar = onTapAvatar
        messagesViewController.onLoadPreviousMessages = onLoadPreviousMessages
        messagesViewController.onTapInvite = onTapInvite
        messagesViewController.onReaction = onReaction
        messagesViewController.onTapReactions = onTapReactions
        messagesViewController.onDoubleTap = onDoubleTap
        messagesViewController.shouldBlurPhotos = shouldBlurPhotos
        messagesViewController.onPhotoRevealed = { key in
            Log.info("[Representable] onPhotoRevealed wrapper called with key: \(key.prefix(50))...")
            self.onPhotoRevealed(key)
        }
        messagesViewController.onPhotoHidden = { key in
            Log.info("[Representable] onPhotoHidden wrapper called with key: \(key.prefix(50))...")
            self.onPhotoHidden(key)
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
        onTapAvatar: { _ in },
        onLoadPreviousMessages: {},
        onTapInvite: { _ in },
        onReaction: { _, _ in },
        onTapReactions: { _ in },
        onDoubleTap: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        bottomBarHeight: bottomBarHeight
    )
    .ignoresSafeArea()
}
