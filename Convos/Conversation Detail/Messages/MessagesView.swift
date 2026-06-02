import ConvosCore
import ConvosCoreiOS
import SwiftUI
import SwiftUIIntrospect

enum MessagesViewTopBarTrailingItem {
    case share, scan
}

struct MessagesView<BottomBarContent: View>: View {
    /// Owned by the parent (`ConversationView`) so it can react to the
    /// long-press context menu being presented — currently used to lock
    /// the conversation/stuff pager so a swipe mid-press doesn't drag the
    /// user out of the conversation into the stuff page.
    @Bindable var contextMenuState: MessageContextMenuState
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
    /// True when the staged invite is a side-convo the user created via the
    /// Convos button (name / image / explode are editable). False for a pasted
    /// invite into an existing conversation, which renders read-only.
    var pendingInviteIsEditable: Bool = true
    var pendingInviteEmoji: String?
    @Binding var pendingInviteConvoName: String
    @Binding var pendingInviteImage: UIImage?
    var pendingInviteExplodeDuration: ExplodeDuration?
    var onSetInviteExplodeDuration: ((ExplodeDuration?) -> Void)?
    var onInviteConvoNameEditingEnded: ((String) -> Void)?
    var pendingAgentShareName: String?
    var pendingAgentShareEmoji: String?
    var pendingAgentShareSummary: String?
    var isShowingAgentShareChip: Bool = false
    var onClearAgentShare: (() -> Void)?
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
    var onTapAgentShare: (MessageAgentShare) -> Void = { _ in }
    var agentShareResolver: any AgentShareResolving = MockAgentShareResolver()
    var inviteMembershipResolver: any InviteMembershipResolving = NoopInviteMembershipResolver()
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
    @State private var isPhotoPickerPresented: Bool = false
    @State private var scrollToBottom: (() -> Void)?
    @State private var notifyMessageInputFocused: (() -> Void)?
    /// Drives the SwiftUI sheet presentation of `AttachmentPreviewSheet`
    /// for HTML attachments. Non-HTML previews still go through the
    /// UIKit path in `MessagesViewController.presentAttachmentPreview`.
    @State private var htmlAttachmentPreview: HTMLAttachmentPreviewItem?
    /// Shared namespace between the `HTMLAttachmentBubble` source and
    /// the sheet's `.navigationTransition(.zoom(...))` destination.
    @Namespace private var htmlAttachmentTransitionNamespace: Namespace.ID

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
            onTapAgentShare: onTapAgentShare,
            agentShareResolver: agentShareResolver,
            inviteMembershipResolver: inviteMembershipResolver,
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
            htmlAttachmentTransitionNamespace: htmlAttachmentTransitionNamespace,
            onPresentHTMLAttachmentPreview: { attachment, fileURL, sender, sentAt in
                htmlAttachmentPreview = HTMLAttachmentPreviewItem(
                    attachment: attachment,
                    fileURL: fileURL,
                    sender: sender,
                    sentAt: sentAt
                )
            },
            bottomBarHeight: bottomBarHeight + extraBottomInset,
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
                    pendingInviteIsEditable: pendingInviteIsEditable,
                    pendingInviteEmoji: pendingInviteEmoji,
                    pendingInviteConvoName: $pendingInviteConvoName,
                    pendingInviteImage: $pendingInviteImage,
                    pendingInviteExplodeDuration: pendingInviteExplodeDuration,
                    onSetInviteExplodeDuration: onSetInviteExplodeDuration,
                    onInviteConvoNameEditingEnded: onInviteConvoNameEditingEnded,
                    pendingAgentShareName: pendingAgentShareName,
                    pendingAgentShareEmoji: pendingAgentShareEmoji,
                    pendingAgentShareSummary: pendingAgentShareSummary,
                    isShowingAgentShareChip: isShowingAgentShareChip,
                    onClearAgentShare: onClearAgentShare,
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
            // The overlay renders in a separate tree from the message cells,
            // so it doesn't inherit the cell's resolver injection. Provide it
            // here so an agent-share card preview resolves real data, not the
            // env-default mock.
            .environment(\.agentShareResolver, agentShareResolver)
            .environment(\.inviteMembershipResolver, inviteMembershipResolver)
        }
        .sheet(item: $htmlAttachmentPreview) { item in
            AttachmentPreviewSheet(
                attachment: item.attachment,
                fileURL: item.fileURL,
                sender: item.sender,
                sentAt: item.sentAt,
                profileSheetContent: profileSheetForMember
            )
            .navigationTransition(.zoom(sourceID: item.attachment.key, in: htmlAttachmentTransitionNamespace))
        }
    }
}

/// Identifiable payload carried into the SwiftUI `.sheet(item:)` that
/// presents an HTML attachment. Wraps the fields the UIKit
/// `MessagesViewController.openFileAttachment` already loads - the
/// representable bridges the call into SwiftUI state when an HTML
/// attachment is tapped, so the matched-geometry zoom transition can fire.
struct HTMLAttachmentPreviewItem: Identifiable, Equatable {
    let id: UUID = UUID()
    let attachment: HydratedAttachment
    let fileURL: URL
    let sender: ConversationMember
    let sentAt: Date
}
