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
    let onTapReactions: (AnyMessage) -> Void
    let onDoubleTap: (AnyMessage) -> Void
    let onDisplayNameEndedEditing: () -> Void
    let onProfileSettings: () -> Void
    let onLoadPreviousMessages: () -> Void
    let shouldBlurPhotos: Bool
    let onPhotoRevealed: () -> Void
    @ViewBuilder let bottomBarContent: () -> BottomBarContent

    @State private var bottomBarHeight: CGFloat = 0.0
    @State private var isPhotoPickerPresented: Bool = false

    var body: some View {
        Group {
            MessagesViewRepresentable(
                conversation: conversation,
                messages: messages,
                invite: invite,
                onUserInteraction: onUserInteraction,
                hasLoadedAllMessages: hasLoadedAllMessages,
                shouldBlurPhotos: shouldBlurPhotos,
                onTapAvatar: onTapAvatar,
                onLoadPreviousMessages: onLoadPreviousMessages,
                onTapInvite: onTapInvite,
                onReaction: onReaction,
                onTapReactions: onTapReactions,
                onDoubleTap: onDoubleTap,
                onPhotoRevealed: onPhotoRevealed,
                onPhotoHidden: { _ in },
                bottomBarHeight: bottomBarHeight
            )
            .ignoresSafeArea()
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
                onSendMessage: onSendMessage,
                onDisplayNameEndedEditing: onDisplayNameEndedEditing,
                onProfileSettings: onProfileSettings,
                onBaseHeightChanged: { height in
                    bottomBarHeight = height
                },
                bottomBarContent: bottomBarContent
            )
        }
    }
}
