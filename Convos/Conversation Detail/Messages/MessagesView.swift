import ConvosCore
import SwiftUI
import SwiftUIIntrospect

enum MessagesViewTopBarTrailingItem {
    case share, scan
}

struct MessagesView<BottomBarContent: View>: View {
    let conversation: Conversation
    let messages: [MessagesListItemType]
    let invite: Invite
    let hasLoadedAllMessages: Bool
    let profile: Profile
    let untitledConversationPlaceholder: String
    let conversationNamePlaceholder: String
    @Binding var conversationName: String
    @Binding var conversationImage: UIImage?
    @Binding var displayName: String
    @Binding var messageText: String
    @Binding var selectedAttachmentImage: UIImage?
    let sendButtonEnabled: Bool
    @Binding var profileImage: UIImage?
    let onboardingCoordinator: ConversationOnboardingCoordinator
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let messagesTextFieldEnabled: Bool
    let onUserInteraction: () -> Void
    let onProfilePhotoTap: () -> Void
    let onSendMessage: () -> Void
    let onTapAvatar: (ConversationMember) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onReaction: (String, String) -> Void
    let onToggleReaction: (String, String) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onReply: (AnyMessage) -> Void
    let onDoubleTap: (AnyMessage) -> Void
    let replyingToMessage: AnyMessage?
    let onCancelReply: () -> Void
    let onDisplayNameEndedEditing: () -> Void
    let onProfileSettings: () -> Void
    let onLoadPreviousMessages: () -> Void
    let shouldBlurPhotos: Bool
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    @ViewBuilder let bottomBarContent: () -> BottomBarContent

    @State private var bottomBarHeight: CGFloat = 0.0
    @State private var contextMenuState: MessageContextMenuState = .init()
    @State private var isPhotoPickerPresented: Bool = false
    @State private var scrollToBottom: (() -> Void)?

    var body: some View {
        ZStack {
            MessagesViewRepresentable(
                conversation: conversation,
                messages: messages,
                invite: invite,
                onUserInteraction: onUserInteraction,
                hasLoadedAllMessages: hasLoadedAllMessages,
                shouldBlurPhotos: shouldBlurPhotos,
                focusCoordinator: focusCoordinator,
                onTapAvatar: onTapAvatar,
                onLoadPreviousMessages: onLoadPreviousMessages,
                onTapInvite: onTapInvite,
                onReaction: onReaction,
                onTapReactions: onTapReactions,
                onReply: onReply,
                contextMenuState: contextMenuState,
                onDoubleTap: onDoubleTap,
                onPhotoRevealed: onPhotoRevealed,
                onPhotoHidden: onPhotoHidden,
                onPhotoDimensionsLoaded: onPhotoDimensionsLoaded,
                bottomBarHeight: bottomBarHeight,
                scrollToBottomTrigger: { scrollFn in
                    scrollToBottom = scrollFn
                }
            )
            .ignoresSafeArea()

            MessageContextMenuOverlay(
                state: contextMenuState,
                shouldBlurPhotos: shouldBlurPhotos,
                onReaction: onReaction,
                onReply: { message in
                    onReply(message)
                },
                onCopy: { text in
                    UIPasteboard.general.string = text
                },
                onPhotoRevealed: onPhotoRevealed,
                onPhotoHidden: onPhotoHidden
            )
        }
        .safeAreaBar(edge: .bottom) {
            MessagesBottomBar(
                profile: profile,
                displayName: $displayName,
                messageText: $messageText,
                selectedAttachmentImage: $selectedAttachmentImage,
                sendButtonEnabled: sendButtonEnabled,
                profileImage: $profileImage,
                isPhotoPickerPresented: $isPhotoPickerPresented,
                focusState: $focusState,
                focusCoordinator: focusCoordinator,
                onboardingCoordinator: onboardingCoordinator,
                messagesTextFieldEnabled: messagesTextFieldEnabled,
                onProfilePhotoTap: onProfilePhotoTap,
                onSendMessage: {
                    scrollToBottom?()
                    onSendMessage()
                },
                onDisplayNameEndedEditing: onDisplayNameEndedEditing,
                onProfileSettings: onProfileSettings,
                onBaseHeightChanged: { height in
                    bottomBarHeight = height
                },
                bottomBarContent: {
                    bottomBarContent()
                    if let replyingToMessage {
                        ReplyComposerBar(
                            message: replyingToMessage,
                            shouldBlurPhotos: shouldBlurPhotos,
                            onDismiss: onCancelReply
                        )
                    }
                }
            )
            .opacity(contextMenuState.isPresented ? 0.0 : 1.0)
            .animation(.easeOut(duration: 0.2), value: contextMenuState.isPresented)
        }
        .onAppear {
            contextMenuState.onReaction = onReaction
            contextMenuState.onToggleReaction = onToggleReaction
        }
    }
}
