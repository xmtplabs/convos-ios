import ConvosCore
import ConvosCoreiOS
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
    var isVideoAttachment: Bool = false
    var composerLinkPreview: LinkPreview?
    var pendingInviteURL: String?
    var pendingInviteEmoji: String?
    @Binding var pendingInviteConvoName: String
    @Binding var pendingInviteImage: UIImage?
    var pendingInviteExplodeDuration: ExplodeDuration?
    var onSetInviteExplodeDuration: ((ExplodeDuration?) -> Void)?
    var onInviteConvoNameEditingEnded: ((String) -> Void)?
    let sendButtonEnabled: Bool
    @Binding var profileImage: UIImage?
    let onboardingCoordinator: ConversationOnboardingCoordinator
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let messagesTextFieldEnabled: Bool
    let onUserInteraction: () -> Void
    let onProfilePhotoTap: () -> Void
    let onSendMessage: () -> Void
    let onClearInvite: () -> Void
    let onClearLinkPreview: () -> Void
    let onTapAvatar: (ConversationMember) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onReaction: (String, String) -> Void
    let onToggleReaction: (String, String) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onReply: (AnyMessage) -> Void
    let replyingToMessage: AnyMessage?
    var replyingToAudioTranscriptText: String?
    let onCancelReply: () -> Void
    let onDisplayNameEndedEditing: () -> Void
    let onProfileSettings: () -> Void
    let onLoadPreviousMessages: () -> Void
    let shouldBlurPhotos: Bool
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let onVideoSelected: (URL) -> Void
    let onAboutAssistants: () -> Void
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
    let onBottomOverscrollChanged: (CGFloat) -> Void
    let onBottomOverscrollReleased: (CGFloat) -> Void
    let onVoiceMemoTap: () -> Void
    @Bindable var voiceMemoRecorder: VoiceMemoRecorder
    let onSendVoiceMemo: () -> Void
    let onConvosAction: () -> Void
    @ViewBuilder let bottomBarContent: () -> BottomBarContent

    @State private var bottomBarHeight: CGFloat = 0.0
    @State private var contextMenuState: MessageContextMenuState = .init()
    @State private var isPhotoPickerPresented: Bool = false
    @State private var scrollToBottom: (() -> Void)?

    var body: some View {
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
            onPhotoRevealed: onPhotoRevealed,
            onPhotoHidden: onPhotoHidden,
            onPhotoDimensionsLoaded: onPhotoDimensionsLoaded,
            onAgentOutOfCredits: onAgentOutOfCredits,
            onTapUpdateMember: onTapUpdateMember,
            onRetryMessage: onRetryMessage,
            onDeleteMessage: onDeleteMessage,
            onRetryAssistantJoin: onRetryAssistantJoin,
            onCopyInviteLink: onCopyInviteLink,
            onConvoCode: onConvoCode,
            onInviteAssistant: onInviteAssistant,
            onRetryTranscript: onRetryTranscript,
            hasAssistant: hasAssistant,
            isAssistantJoinPending: isAssistantJoinPending,
            isAssistantEnabled: isAssistantEnabled,
            bottomBarHeight: bottomBarHeight,
            onBottomOverscrollChanged: onBottomOverscrollChanged,
            onBottomOverscrollReleased: onBottomOverscrollReleased,
            scrollToBottomTrigger: { scrollFn in
                scrollToBottom = scrollFn
            }
        )
        .ignoresSafeArea()
        .safeAreaBar(edge: .bottom) {
            MessagesBottomBar(
                profile: profile,
                displayName: $displayName,
                messageText: $messageText,
                selectedAttachmentImage: $selectedAttachmentImage,
                isVideoAttachment: isVideoAttachment,
                composerLinkPreview: composerLinkPreview,
                pendingInviteURL: pendingInviteURL,
                pendingInviteEmoji: pendingInviteEmoji,
                pendingInviteConvoName: $pendingInviteConvoName,
                pendingInviteImage: $pendingInviteImage,
                pendingInviteExplodeDuration: pendingInviteExplodeDuration,
                onSetInviteExplodeDuration: onSetInviteExplodeDuration,
                onInviteConvoNameEditingEnded: onInviteConvoNameEditingEnded,
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
                onClearInvite: onClearInvite,
                onClearLinkPreview: onClearLinkPreview,
                onDisplayNameEndedEditing: onDisplayNameEndedEditing,
                onVideoSelected: onVideoSelected,
                onProfileSettings: onProfileSettings,
                onVoiceMemoTap: onVoiceMemoTap,
                voiceMemoRecorder: voiceMemoRecorder,
                onSendVoiceMemo: onSendVoiceMemo,
                onConvosAction: onConvosAction,
                onBaseHeightChanged: { height in
                    bottomBarHeight = height
                },
                bottomBarContent: {
                    bottomBarContent()
                    if let replyingToMessage {
                        ReplyComposerBar(
                            message: replyingToMessage,
                            shouldBlurPhotos: shouldBlurPhotos,
                            audioTranscriptText: replyingToAudioTranscriptText,
                            onDismiss: onCancelReply
                        )
                    }
                }
            )
            .opacity(contextMenuState.isPresented ? 0.0 : 1.0)
            .allowsHitTesting(!contextMenuState.isPresented)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: contextMenuState.isPresented)
        }
        .overlay {
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
        .onAppear {
            contextMenuState.onReaction = onReaction
            contextMenuState.onToggleReaction = onToggleReaction
        }
    }
}
