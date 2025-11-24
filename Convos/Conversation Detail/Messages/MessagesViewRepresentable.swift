import ConvosCore
import SwiftUI

struct MessagesViewRepresentable: UIViewControllerRepresentable {
    let conversation: Conversation
    let messages: [MessagesListItemType]
    let invite: Invite
    let scrollViewWillBeginDragging: () -> Void
    let hasLoadedAllMessages: Bool
    let onTapMessage: (AnyMessage) -> Void
    let onTapAvatar: (ConversationMember) -> Void
    let onLoadPreviousMessages: () -> Void
    let bottomBarHeight: CGFloat

    func makeUIViewController(context: Context) -> MessagesViewController {
        return MessagesViewController()
    }

    func updateUIViewController(_ messagesViewController: MessagesViewController, context: Context) {
        messagesViewController.scrollViewWillBeginDragging = scrollViewWillBeginDragging
        messagesViewController.bottomBarHeight = bottomBarHeight
        messagesViewController.onTapMessage = onTapMessage
        messagesViewController.onTapAvatar = onTapAvatar
        messagesViewController.onLoadPreviousMessages = onLoadPreviousMessages
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
        scrollViewWillBeginDragging: {},
        hasLoadedAllMessages: false,
        onTapMessage: { _ in },
        onTapAvatar: { _ in },
        onLoadPreviousMessages: {},
        bottomBarHeight: bottomBarHeight
    )
    .ignoresSafeArea()
}
