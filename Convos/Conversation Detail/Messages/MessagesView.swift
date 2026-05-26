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
    var pendingMediaAttachments: [PendingMediaAttachment] = []
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
    var isReadOnly: Bool = false
    let onUserInteraction: () -> Void
    let onProfilePhotoTap: () -> Void
    let onSendMessage: () -> Void
    let onClearInvite: () -> Void
    let onClearLinkPreview: () -> Void
    let onClearMediaAttachment: (UUID) -> Void
    let onTapAvatar: (ConversationMember) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onReaction: (String, String) -> Void
    let onToggleReaction: (String, String) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onTapReadReceipts: (MessagesGroup) -> Void
    let onTapThinkingIndicator: (ThinkingSessionDescriptor) -> Void
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
    let onPhotoSelected: (UIImage) -> Void
    let onVideoSelected: (URL) -> Void
    let onFileSelected: (URL, String, String, Int) -> Void
    let onAboutAgents: () -> Void
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
    let onBottomOverscrollChanged: (CGFloat) -> Void
    let onBottomOverscrollReleased: (CGFloat) -> Void
    let onVoiceMemoTap: () -> Void
    @Bindable var voiceMemoRecorder: VoiceMemoRecorder
    let onSendVoiceMemo: () -> Void
    let onConvosAction: () -> Void
    /// `nil` unless `FeatureFlags.isDebugInjectorEnabled` is on (hard-locked off
    /// in production); the testtube button stays hidden in any other case.
    var onDebugAttachmentTap: (() -> Void)?
    var extraBottomInset: CGFloat = 0.0
    @ViewBuilder let bottomBarContent: () -> BottomBarContent

    @State private var bottomBarHeight: CGFloat = 0.0
    @State private var contextMenuState: MessageContextMenuState = .init()
    @State private var isPhotoPickerPresented: Bool = false
    @State private var scrollToBottom: (() -> Void)?
    @State private var notifyMessageInputFocused: (() -> Void)?

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
            onToggleReaction: onToggleReaction,
            onTapReactions: onTapReactions,
            onTapReadReceipts: onTapReadReceipts,
            onTapThinkingIndicator: onTapThinkingIndicator,
            onReply: onReply,
            contextMenuState: contextMenuState,
            onPhotoRevealed: onPhotoRevealed,
            onPhotoHidden: onPhotoHidden,
            onPhotoDimensionsLoaded: onPhotoDimensionsLoaded,
            onAgentOutOfCredits: onAgentOutOfCredits,
            creditsDepleted: creditsDepleted,
            onTapUpdateMember: onTapUpdateMember,
            onRetryMessage: onRetryMessage,
            onDeleteMessage: onDeleteMessage,
            onRetryAgentJoin: onRetryAgentJoin,
            onCopyInviteLink: onCopyInviteLink,
            onConvoCode: onConvoCode,
            onInviteAgent: onInviteAgent,
            onRetryTranscript: onRetryTranscript,
            profileSheetForMember: profileSheetForMember,
            memberContactOverride: memberContactOverride,
            hasAgent: hasAgent,
            isAgentJoinPending: isAgentJoinPending,
            headerMode: headerMode,
            agentBuilderSummary: agentBuilderSummary,
            agentBuilderTransitionNamespace: agentBuilderTransitionNamespace,
            bottomBarHeight: bottomBarHeight + extraBottomInset,
            onBottomOverscrollChanged: onBottomOverscrollChanged,
            onBottomOverscrollReleased: onBottomOverscrollReleased,
            scrollToBottomTrigger: { scrollFn in
                scrollToBottom = scrollFn
            },
            messageInputFocusTrigger: { fn in
                notifyMessageInputFocused = fn
            }
        )
        .ignoresSafeArea()
        .onChange(of: focusState) { oldValue, newValue in
            if newValue == .message && oldValue != .message {
                notifyMessageInputFocused?()
            }
        }
        .environment(\.isConversationReadOnly, isReadOnly)
        .safeAreaBar(edge: .bottom) {
            if !isReadOnly {
                MessagesBottomBar(
                    profile: profile,
                    displayName: $displayName,
                    messageText: $messageText,
                    pendingMediaAttachments: pendingMediaAttachments,
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
                    onClearMediaAttachment: onClearMediaAttachment,
                    onDisplayNameEndedEditing: onDisplayNameEndedEditing,
                    onPhotoSelected: onPhotoSelected,
                    onVideoSelected: onVideoSelected,
                    onFileSelected: onFileSelected,
                    onProfileSettings: onProfileSettings,
                    onVoiceMemoTap: onVoiceMemoTap,
                    voiceMemoRecorder: voiceMemoRecorder,
                    onSendVoiceMemo: onSendVoiceMemo,
                    onConvosAction: onConvosAction,
                    onDebugAttachmentTap: onDebugAttachmentTap,
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
        }
        .overlay {
            MessageContextMenuOverlay(
                state: contextMenuState,
                shouldBlurPhotos: shouldBlurPhotos,
                isReadOnly: isReadOnly,
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
    }
}
