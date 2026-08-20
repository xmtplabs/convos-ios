import ConvosComposer
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
    /// the conversation/things pager so a swipe mid-press doesn't drag the
    /// user out of the conversation into the things page.
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
    var messagePlaceholder: String = "Chat"
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
    let onSendMessage: () -> Void
    let onClearInvite: () -> Void
    let onClearLinkPreview: () -> Void
    let onClearMediaAttachment: (UUID) -> Void
    let onTapAvatar: (ConversationMember) -> Void
    let onTapInvite: (MessageInvite) -> Void
    var onTapAgentShare: (MessageAgentShare) -> Void = { _ in }
    /// Offered every link tapped in the transcript before the in-app browser
    /// gets it; see `MessageLinkRouter`.
    var messageLinkRouter: MessageLinkRouter = { _ in false }
    /// The conversation's own Space; see `SpaceLink`.
    var conversationSpaceURL: URL?
    var agentShareResolver: any AgentShareResolving = MockAgentShareResolver()
    var inviteMembershipResolver: any InviteMembershipResolving = NoopInviteMembershipResolver()
    let onReaction: (String, String) -> Void
    let onToggleReaction: (String, String) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onTapReadReceipts: (MessagesGroup) -> Void
    let onTapThinkingIndicator: (ThinkingSessionDescriptor) -> Void
    let onReply: (AnyMessage) -> Void
    var onOpenMessageDetail: ((AnyMessage) -> Void)?
    var expandedMessageIds: Set<String> = []
    var onToggleMessageExpanded: (String) -> Void = { _ in }
    let replyingToMessage: AnyMessage?
    var replyingToAudioTranscriptText: String?
    let onCancelReply: () -> Void
    var pendingWidgetReplyContext: ContextReplyContext?
    var onCancelWidgetReply: () -> Void = {}
    let onDisplayNameEndedEditing: () -> Void
    let onProfileSettings: () -> Void
    let onLoadPreviousMessages: () -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let onPhotoSelected: (UIImage) -> Void
    let onVideoSelected: (URL) -> Void
    let onFileSelected: (URL, String, String, Int) -> Void
    let onAboutAgents: () -> Void
    let onAgentOutOfCredits: () -> Void
    let agentPowerDepletedByInboxId: [String: Bool]
    let onTapUpdateMember: (ConversationMember) -> Void
    var onTapCapabilityConnect: (CapabilityConnectPrompt) -> Void = { _ in }
    let onRetryMessage: (AnyMessage) -> Void
    let onDeleteMessage: (AnyMessage) -> Void
    let onRetryAgentJoin: () -> Void
    let onInviteAgent: () -> Void
    var onInvitePeople: () -> Void = {}
    let onRetryTranscript: (VoiceMemoTranscriptListItem) -> Void
    let profileSheetForMember: (ConversationMember) -> AnyView
    let memberContactOverride: (String) -> Contact?
    let isAgentJoinPending: Bool
    var headerMode: MessagesHeaderMode = .standard
    var agentBuilderSummary: AgentBuilderSummary?
    var agentBuilderTransitionNamespace: Namespace.ID?
    let onVoiceMemoTap: () -> Void
    @Bindable var voiceMemoRecorder: VoiceMemoRecorder
    let onSendVoiceMemo: () -> Void
    /// `nil` unless `FeatureFlags.isDebugInjectorEnabled` is on (hard-locked off
    /// in production); the testtube button stays hidden in any other case.
    var onDebugAttachmentTap: (() -> Void)?
    var extraBottomInset: CGFloat = 0.0
    /// Clearance at the transcript's top for a host that floats chrome over it.
    /// The conversation's segmented control sits there; see
    /// `ConversationChromeMetrics.contentClearance`.
    var topContentInset: CGFloat = 0.0
    /// False when the composer is hosted externally: the transcript renders no
    /// bar of its own and insets purely by `extraBottomInset`.
    var hostsBottomBar: Bool = true
    /// Agent-style composer: the `+` menu gains `.connections`. Forwarded to
    /// `MessagesBottomBar`.
    var usesAgentComposerLayout: Bool = false
    /// Host gate for the `+` menu's `.connections` row; the composer package
    /// cannot read the app's feature flags.
    var connectionsEnabled: Bool = false
    /// Presents the host's Connections browser; the composer only emits the tap.
    var onConnectionsTap: (() -> Void)?
    /// True when the host renders the message long-press menu itself, so this
    /// view renders none. Set by the conversation sheet, which layers the menu
    /// at its own root: this view is clipped to the sheet's current detent, and
    /// a menu inside that clip would be cropped.
    var hostRendersContextMenu: Bool = false
    /// Surfaces the transcript's scroll-to-bottom trigger to an external
    /// composer host, which fires it on send (the internal bar wires this
    /// itself).
    /// Surfaces the transcript's content height to the host, which sizes the
    /// conversation sheet's detents to it.
    var onContentHeightChanged: ((CGFloat) -> Void)?
    var onScrollToBottomAvailable: ((@escaping (Bool) -> Void) -> Void)?
    @ViewBuilder let bottomBarContent: () -> BottomBarContent

    /// Set by a host that shows less of this view than the frame it hands over -
    /// the conversation sheet. Zero for every other host.
    @State private var bottomBarHeight: CGFloat = 0.0
    /// See the `ignoresSafeArea` call in `body`.
    private var ignoredSafeAreaRegions: SafeAreaRegions {
        hostsBottomBar ? .all : .container
    }
    @State private var isPhotoPickerPresented: Bool = false
    @State private var scrollToBottom: ((Bool) -> Void)?
    @State private var notifyMessageInputFocused: (() -> Void)?
    /// Drives the SwiftUI sheet presentation of `AttachmentPreviewSheet`
    /// for HTML attachments. Non-HTML previews still go through the
    /// UIKit path in `MessagesViewController.presentAttachmentPreview`.
    @State private var htmlAttachmentPreview: HTMLAttachmentPreviewItem?
    /// Same bridge for non-HTML file attachments (PDFs etc.) - no zoom
    /// transition, just the preview sheet.
    @State private var fileAttachmentPreview: FileAttachmentPreviewItem?
    /// Shared namespace between the `HTMLAttachmentBubble` source and
    /// the sheet's `.navigationTransition(.zoom(...))` destination.
    @Namespace private var htmlAttachmentTransitionNamespace: Namespace.ID

    @MainActor @ViewBuilder
    private func composerQuickEditView(placeholderText: String, isImagePickerPresented: Binding<Bool>) -> some View {
        QuickEditView(
            placeholderText: placeholderText,
            text: $displayName,
            image: $profileImage,
            isImagePickerPresented: isImagePickerPresented,
            imageAssetIdentifier: Binding(
                get: { ProfileSettingsViewModel.shared.profileImageAssetIdentifier },
                set: { ProfileSettingsViewModel.shared.profileImageAssetIdentifier = $0 }
            ),
            focusState: $focusState,
            focused: .displayName,
            settingsSymbolName: "lanyardcard.fill",
            showsSettingsButton: false,
            onSubmit: onDisplayNameEndedEditing,
            onSettings: onProfileSettings
        )
    }

    private var composerAgentShareChip: some View {
        AgentContactCardChip(
            displayName: pendingAgentShareName ?? "Agent",
            emoji: pendingAgentShareEmoji,
            summary: pendingAgentShareSummary,
            onRemove: { onClearAgentShare?() }
        )
    }

    private var representableAgentBuilderSummaryProvider: (AgentBuilderCardContent) -> AnyView {
        { content in
            AnyView(AgentBuilderSummaryView(
                content: content,
                connectionChipImageName: { identifier in
                    AgentBuilderConnection(rawValue: identifier)?.chipImageName
                }
            ))
        }
    }

    var body: some View {
        MessagesViewRepresentable(
            conversation: conversation,
            messages: messages,
            invite: invite,
            onUserInteraction: onUserInteraction,
            hasLoadedAllMessages: hasLoadedAllMessages,
            focusCoordinator: focusCoordinator,
            onTapAvatar: onTapAvatar,
            onLoadPreviousMessages: onLoadPreviousMessages,
            onTapInvite: onTapInvite,
            onTapAgentShare: onTapAgentShare,
            messageLinkRouter: messageLinkRouter,
            conversationSpaceURL: conversationSpaceURL,
            agentShareResolver: agentShareResolver,
            inviteMembershipResolver: inviteMembershipResolver,
            onReaction: onReaction,
            onToggleReaction: onToggleReaction,
            onTapReactions: onTapReactions,
            onTapReadReceipts: onTapReadReceipts,
            onTapThinkingIndicator: onTapThinkingIndicator,
            onReply: onReply,
            onOpenMessageDetail: onOpenMessageDetail,
            expandedMessageIds: expandedMessageIds,
            onToggleMessageExpanded: onToggleMessageExpanded,
            contextMenuState: contextMenuState,
            onPhotoDimensionsLoaded: onPhotoDimensionsLoaded,
            onAgentOutOfCredits: onAgentOutOfCredits,
            agentPowerDepletedByInboxId: agentPowerDepletedByInboxId,
            onTapUpdateMember: onTapUpdateMember,
            onTapCapabilityConnect: onTapCapabilityConnect,
            onRetryMessage: onRetryMessage,
            onDeleteMessage: onDeleteMessage,
            onRetryAgentJoin: onRetryAgentJoin,
            onInviteAgent: onInviteAgent,
            onInvitePeople: onInvitePeople,
            onRetryTranscript: onRetryTranscript,
            profileSheetForMember: profileSheetForMember,
            memberContactOverride: memberContactOverride,
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
            onPresentFileAttachmentPreview: { attachment, fileURL, sender, sentAt in
                fileAttachmentPreview = FileAttachmentPreviewItem(
                    attachment: attachment,
                    fileURL: fileURL,
                    sender: sender,
                    sentAt: sentAt
                )
            },
            agentBuilderSummaryProvider: representableAgentBuilderSummaryProvider,
            currentUserProfileImage: { ProfileSettingsViewModel.shared.profileImage },
            backwardsSecrecyInfoSheet: { AnyView(BackwardsSecrecyInfoView()) },
            bottomBarHeight: bottomBarHeight + extraBottomInset,
            // Read-only hosts never render the composer (see the
            // `safeAreaBar` below), and external-composer hosts render it in
            // the conversation sheet, so the controller must not wait for a
            // bottom-bar measurement before applying its initial state and
            // revealing the list.
            hasBottomBar: !isReadOnly && hostsBottomBar,
            topContentInset: topContentInset,
            onContentHeightChanged: onContentHeightChanged,
            scrollToBottomTrigger: { scrollFn in
                scrollToBottom = scrollFn
                onScrollToBottomAvailable?(scrollFn)
            },
            messageInputFocusTrigger: { fn in
                notifyMessageInputFocused = fn
            }
        )
        // Which safe areas the list ignores follows who owns the bottom bar,
        // because that is also who owns the keyboard math.
        //
        // Hosting its own bar (the full-screen chat path) means the controller
        // measures the keyboard's overlap itself - see
        // `MessagesViewController.calculateNewBottomInset`. SwiftUI must not
        // inset for the keyboard as well, or the clearance is counted twice and
        // the newest message sits a keyboard's height above the composer.
        //
        // An external bar (a host that positions its own chrome against the
        // keyboard and rises with it) is the opposite case: the controller
        // skips the keyboard math, so the list has to be inset for the keyboard
        // here or it would keep its frame behind one while the chrome moved,
        // and the two would no longer share a bottom edge.
        .ignoresSafeArea(ignoredSafeAreaRegions)
        .onChange(of: focusState) { oldValue, newValue in
            if newValue == .message && oldValue != .message {
                notifyMessageInputFocused?()
            }
        }
        .environment(\.isConversationReadOnly, isReadOnly)
        .safeAreaBar(edge: .bottom) {
            if !isReadOnly && hostsBottomBar {
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
                    isShowingAgentShareChip: isShowingAgentShareChip,
                    sendButtonEnabled: sendButtonEnabled,
                    profileImage: $profileImage,
                    isPhotoPickerPresented: $isPhotoPickerPresented,
                    focusState: $focusState,
                    focusCoordinator: focusCoordinator,
                    messagesTextFieldEnabled: messagesTextFieldEnabled,
                    messagePlaceholder: messagePlaceholder,
                    onSendMessage: {
                        scrollToBottom?(true)
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
                    onDebugAttachmentTap: onDebugAttachmentTap,
                    usesAgentComposerLayout: usesAgentComposerLayout,
                    connectionsEnabled: connectionsEnabled,
                    onConnectionsTap: onConnectionsTap,
                    onBaseHeightChanged: { height in
                        bottomBarHeight = height
                    },
                    bottomBarContent: {
                        bottomBarContent()
                        if let replyingToMessage {
                            ReplyComposerBar(
                                message: replyingToMessage,
                                audioTranscriptText: replyingToAudioTranscriptText,
                                onDismiss: onCancelReply
                            )
                            // The bottom bar is hosted in the representable's
                            // own tree, so inject the resolver directly on the
                            // bar (same reason the context-menu overlay does).
                            .environment(\.agentShareResolver, agentShareResolver)
                        } else if let pendingWidgetReplyContext {
                            WidgetReplyComposerBar(
                                context: pendingWidgetReplyContext,
                                onDismiss: onCancelWidgetReply
                            )
                        }
                    },
                    quickEditView: { placeholderText, isImagePickerPresented in
                        composerQuickEditView(
                            placeholderText: placeholderText,
                            isImagePickerPresented: isImagePickerPresented
                        )
                    },
                    fileAttachmentPreview: { file in
                        ComposerFileAttachmentPreview(file: file)
                    },
                    agentShareChip: {
                        composerAgentShareChip
                    }
                )
                .opacity(contextMenuState.isPresented ? 0.0 : 1.0)
                .allowsHitTesting(!contextMenuState.isPresented)
                .animation(.spring(response: 0.3, dampingFraction: 0.9), value: contextMenuState.isPresented)
            }
        }
        .overlay {
            // Suppressed when the host layers the menu itself. Inside the
            // conversation sheet this view is clipped to the detent's height,
            // which would crop a screen-level menu, so the sheet renders it at
            // its own root instead.
            if !hostRendersContextMenu {
                MessageContextMenuOverlay(
                    state: contextMenuState,
                    isReadOnly: isReadOnly,
                    onReaction: onReaction,
                    onReply: { message in
                        onReply(message)
                    },
                    onCopy: { text in
                        UIPasteboard.general.string = text
                    }
                )
                // The overlay renders in a separate tree from the message
                // cells, so it doesn't inherit the cell's resolver injection.
                // Provide it here so an agent-share card preview resolves real
                // data, not the env-default mock.
                .environment(\.agentShareResolver, agentShareResolver)
                .environment(\.inviteMembershipResolver, inviteMembershipResolver)
                // Same reason: a link tapped in a bubble's menu preview should
                // route where the bubble's own tap routes.
                .environment(\.messageLinkRouter, messageLinkRouter)
                .environment(\.conversationSpaceURL, conversationSpaceURL)
            }
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
        .sheet(item: $fileAttachmentPreview) { item in
            AttachmentPreviewSheet(
                attachment: item.attachment,
                fileURL: item.fileURL,
                sender: item.sender,
                sentAt: item.sentAt,
                profileSheetContent: profileSheetForMember
            )
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

/// Same payload for non-HTML file attachments; presented without the zoom
/// transition (the file bubble has no matched-geometry source).
struct FileAttachmentPreviewItem: Identifiable, Equatable {
    let id: UUID = UUID()
    let attachment: HydratedAttachment
    let fileURL: URL
    let sender: ConversationMember
    let sentAt: Date
}
