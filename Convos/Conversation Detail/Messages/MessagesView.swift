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
    let replyingToMessage: AnyMessage?
    let onCancelReply: () -> Void
    let onDisplayNameEndedEditing: () -> Void
    let onProfileSettings: () -> Void
    let onLoadPreviousMessages: () -> Void
    @ViewBuilder let bottomBarContent: () -> BottomBarContent

    @State private var bottomBarHeight: CGFloat = 0.0
    @State private var contextMenuState: MessageContextMenuState = .init()

    var body: some View {
        ZStack {
            MessagesViewRepresentable(
                conversation: conversation,
                messages: messages,
                invite: invite,
                onUserInteraction: onUserInteraction,
                hasLoadedAllMessages: hasLoadedAllMessages,
                onTapAvatar: onTapAvatar,
                onLoadPreviousMessages: onLoadPreviousMessages,
                onTapInvite: onTapInvite,
                onReaction: onReaction,
                onTapReactions: onTapReactions,
                onReply: onReply,
                contextMenuState: contextMenuState,
                bottomBarHeight: bottomBarHeight
            )
            .ignoresSafeArea()

            MessageContextMenuOverlay(
                state: contextMenuState,
                onReaction: onReaction,
                onReply: { message in
                    onReply(message)
                },
                onCopy: { text in
                    UIPasteboard.general.string = text
                }
            )
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0.0) {
                bottomBarContent()
                if let replyingToMessage {
                    ReplyComposerBar(
                        message: replyingToMessage,
                        onDismiss: onCancelReply
                    )
                }
                MessagesBottomBar(
                    profile: profile,
                    displayName: $displayName,
                    messageText: $messageText,
                    sendButtonEnabled: sendButtonEnabled,
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
            .opacity(contextMenuState.isPresented ? 0.0 : 1.0)
            .animation(.easeOut(duration: 0.2), value: contextMenuState.isPresented)
            .background(HeightReader())
            .onPreferenceChange(HeightPreferenceKey.self) { height in
                bottomBarHeight = height
            }
        }
        .onAppear {
            contextMenuState.onReaction = onReaction
            contextMenuState.onToggleReaction = onToggleReaction
        }
    }
}
