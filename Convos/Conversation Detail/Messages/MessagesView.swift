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
    @Binding var sendButtonEnabled: Bool
    @Binding var profileImage: UIImage?
    let onboardingCoordinator: ConversationOnboardingCoordinator
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let messagesTextFieldEnabled: Bool
    let scrollViewWillBeginDragging: () -> Void
    let onProfilePhotoTap: () -> Void
    let onSendMessage: () -> Void
    let onTapAvatar: (ConversationMember) -> Void
    let onDisplayNameEndedEditing: () -> Void
    let onProfileSettings: () -> Void
    let onLoadPreviousMessages: () -> Void
    @ViewBuilder let bottomBarContent: () -> BottomBarContent

    @State private var bottomBarHeight: CGFloat = 0.0
    var body: some View {
        Group {
            MessagesViewRepresentable(
                conversation: conversation,
                messages: messages,
                invite: invite,
                scrollViewWillBeginDragging: scrollViewWillBeginDragging,
                hasLoadedAllMessages: hasLoadedAllMessages,
                onTapAvatar: onTapAvatar,
                onLoadPreviousMessages: onLoadPreviousMessages,
                bottomBarHeight: bottomBarHeight
            )
            .ignoresSafeArea()
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0.0) {
                bottomBarContent()
                MessagesBottomBar(
                    profile: profile,
                    displayName: $displayName,
                    messageText: $messageText,
                    sendButtonEnabled: $sendButtonEnabled,
                    profileImage: $profileImage,
                    focusState: $focusState,
                    focusCoordinator: focusCoordinator,
                    onboardingCoordinator: onboardingCoordinator,
                    messagesTextFieldEnabled: messagesTextFieldEnabled,
                    onProfilePhotoTap: onProfilePhotoTap,
                    onSendMessage: onSendMessage,
                    onDisplayNameEndedEditing: onDisplayNameEndedEditing,
                    onProfileSettings: onProfileSettings
                )
            }
            .background(HeightReader())
            .onPreferenceChange(HeightPreferenceKey.self) { height in
                bottomBarHeight = height
            }
        }
    }
}
