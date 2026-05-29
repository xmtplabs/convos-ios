import ConvosCore
import ConvosCoreiOS
import SwiftUI

struct ConversationView<MessagesBottomBar: View>: View {
    @Bindable var viewModel: ConversationViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let onScanInviteCode: () -> Void
    let onDeleteConversation: () -> Void
    let messagesTopBarTrailingItem: MessagesViewTopBarTrailingItem
    let messagesTopBarTrailingItemEnabled: Bool
    let messagesTextFieldEnabled: Bool
    var isReadOnly: Bool = false
    /// Hide the trailing toolbar item (the "+" add menu / scan button)
    /// without removing the rest of the toolbar. Used by the Agent
    /// Builder to keep the bar clean during the draft phase, then bring
    /// the item in once the user commits via Make.
    var topBarTrailingHidden: Bool = false
    /// Controls the messages list's leading empty-state view (QR invite +
    /// identity, or the `ConversationInfoPreview`). Defaults to `.standard`
    /// in normal chat. The Agent Builder passes `.hidden` so the
    /// underlying chat doesn't flash a QR while the user is still drafting.
    var headerMode: MessagesHeaderMode = .standard
    /// Shared SwiftUI namespace used by the Agent Builder commit morph.
    /// Set by `AgentBuilderView` so its composer card and the in-stream
    /// summary cell can match-geometry into each other via `glassEffectID`.
    var agentBuilderTransitionNamespace: Namespace.ID?
    @ViewBuilder let bottomBarContent: () -> MessagesBottomBar

    @State private var showingLockedInfo: Bool = false
    @State private var showingFullInfo: Bool = false
    @State private var showingAgentsInfo: Bool = false
    @State private var scrollOverscrollAmount: CGFloat = 0.0
    @State private var didReleasePastThreshold: Bool = false
    @State private var pagerSelectedPage: ConversationPagerPage = .messages
    @State private var isKeyboardVisible: Bool = false
    /// Lifted out of `MessagesView` so this view can gate the pager
    /// against horizontal swipes while the long-press context menu is
    /// presented.
    @State private var contextMenuState: MessageContextMenuState = .init()
    @State private var showingDebugInjector: Bool = false
    @State private var presentingAddFromContactsPicker: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction

    /// Substitutes the user's contact (name + avatar) for any member's
    /// per-conversation profile when the inbox is a known contact. The
    /// chat surfaces this so the join-system row reads
    /// "Alice joined" with Alice's avatar instead of "Somebody" + S
    /// monogram while Alice has not yet published her per-conversation
    /// profile. Built once per `ConversationView` lifetime; reads
    /// through the messaging service's contacts repository.
    private var contactOverride: @Sendable (String) -> Contact? {
        viewModel.messagingService.contactsRepository().contact(for:)
    }

    private var showPullToAddAgent: Bool {
        !viewModel.conversation.hasAgent && !viewModel.isAgentJoinPending
    }

    private var messagesView: some View {
        @Bindable var onboardingCoordinator = viewModel.onboardingCoordinator
        return MessagesView(
            contextMenuState: contextMenuState,
            conversation: viewModel.conversation,
            messages: viewModel.messagesWithThinkingIndicators,
            invite: viewModel.invite,
            hasLoadedAllMessages: viewModel.hasLoadedAllMessages,
            profile: viewModel.profile,
            untitledConversationPlaceholder: viewModel.untitledConversationPlaceholder,
            conversationNamePlaceholder: viewModel.conversationNamePlaceholder,
            conversationName: $viewModel.editingConversationName,
            conversationImage: $viewModel.conversationImage,
            displayName: $viewModel.myProfileViewModel.editingDisplayName,
            messageText: $viewModel.messageText,
            pendingMediaAttachments: viewModel.isAwaitingBuilderBundleSend ? [] : viewModel.pendingMediaAttachments,
            composerLinkPreview: viewModel.pastedLinkPreview,
            pendingInviteURL: viewModel.pendingInvite?.fullURL,
            pendingInviteEmoji: viewModel.conversation.conversationEmoji,
            pendingInviteConvoName: $viewModel.pendingInviteConvoName,
            pendingInviteImage: $viewModel.pendingInviteImage,
            pendingInviteExplodeDuration: viewModel.pendingInvite?.explodeDuration,
            onSetInviteExplodeDuration: { duration in viewModel.setInviteExplodeDuration(duration) },
            onInviteConvoNameEditingEnded: { name in
                viewModel.updateLinkedConversationName(name)
                focusCoordinator.endEditing(for: .sideConvoName, context: .quickEditor)
            },
            sendButtonEnabled: viewModel.sendButtonEnabled,
            profileImage: $viewModel.myProfileViewModel.profileImage,
            onboardingCoordinator: onboardingCoordinator,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            messagesTextFieldEnabled: messagesTextFieldEnabled,
            isReadOnly: isReadOnly,
            onUserInteraction: {
                viewModel.dismissQuickEditor()
                focusCoordinator.dismissQuickEditor()
            },
            onProfilePhotoTap: {
                onboardingCoordinator.didTapProfilePhoto()
                viewModel.onProfilePhotoTap(focusCoordinator: focusCoordinator)
            },
            onSendMessage: {
                viewModel.onSendMessage(focusCoordinator: focusCoordinator)
            },
            onClearInvite: viewModel.clearPendingInvite,
            onClearLinkPreview: { viewModel.pastedLinkPreview = nil },
            onClearMediaAttachment: viewModel.removeMediaAttachment(id:),
            onTapAvatar: viewModel.onTapAvatar(_:),
            onTapInvite: viewModel.onTapInvite(_:),
            onReaction: viewModel.onReaction(emoji:messageId:),
            onToggleReaction: viewModel.onReaction(emoji:messageId:),
            onTapReactions: viewModel.onTapReactions(_:),
            onTapReadReceipts: viewModel.onTapReadReceipts(_:),
            onTapThinkingIndicator: { descriptor in
                viewModel.presentingThinkingDetail = descriptor
            },
            onReply: { message in
                viewModel.onReply(message)
                focusCoordinator.moveFocus(to: .message)
            },
            replyingToMessage: viewModel.replyingToMessage,
            replyingToAudioTranscriptText: viewModel.replyingToAudioTranscriptText,
            onCancelReply: viewModel.cancelReply,
            onDisplayNameEndedEditing: {
                viewModel.onDisplayNameEndedEditing(focusCoordinator: focusCoordinator, context: .quickEditor)
            },
            onProfileSettings: viewModel.onProfileSettings,
            onLoadPreviousMessages: viewModel.loadPreviousMessages,
            shouldBlurPhotos: viewModel.shouldBlurPhotos,
            onPhotoRevealed: viewModel.onPhotoRevealed(_:),
            onPhotoHidden: viewModel.onPhotoHidden(_:),
            onPhotoDimensionsLoaded: viewModel.onPhotoDimensionsLoaded(_:width:height:),
            onPhotoSelected: viewModel.addPhotoAttachment(_:),
            onVideoSelected: viewModel.addVideoAttachment(url:),
            onFileSelected: viewModel.addFileAttachment(url:filename:mimeType:fileSize:),
            onAboutAgents: { showingAgentsInfo = true },
            onAgentOutOfCredits: { viewModel.presentingPaywall = true },
            creditsDepleted: viewModel.creditsDepleted,
            onTapUpdateMember: { viewModel.presentingProfileForMember = $0 },
            onRetryMessage: viewModel.retryMessage(_:),
            onDeleteMessage: viewModel.deleteMessage(_:),
            onRetryAgentJoin: { viewModel.requestAgentJoin() },
            onCopyInviteLink: { viewModel.copyInviteLink() },
            onConvoCode: {
                if viewModel.isFull {
                    showingFullInfo = true
                } else {
                    viewModel.presentingShareView = true
                }
            },
            onInviteAgent: { viewModel.onRequestAgentJoin() },
            onRetryTranscript: { item in
                viewModel.retryTranscript(for: item)
            },
            profileSheetForMember: profileSheetForMember,
            memberContactOverride: contactOverride,
            hasAgent: viewModel.conversation.hasAgent,
            isAgentJoinPending: viewModel.isAgentJoinPending,
            headerMode: isReadOnly ? .suppressed : headerMode,
            agentBuilderSummary: viewModel.agentBuilderSummary,
            agentBuilderTransitionNamespace: agentBuilderTransitionNamespace,
            onBottomOverscrollChanged: { overscroll in
                scrollOverscrollAmount = overscroll
                if overscroll == 0 {
                    didReleasePastThreshold = false
                }
            },
            onBottomOverscrollReleased: { overscroll in
                if overscroll >= PullToAddAgentView.activationThreshold,
                   !viewModel.isAgentJoinPending {
                    didReleasePastThreshold = true
                }
            },
            onVoiceMemoTap: { viewModel.onVoiceMemoTapped() },
            voiceMemoRecorder: viewModel.voiceMemoRecorder,
            onSendVoiceMemo: { viewModel.sendVoiceMemo() },
            onConvosAction: { viewModel.onConvosButtonTapped() },
            onDebugAttachmentTap: debugAttachmentTapHandler,
            extraBottomInset: pagerDotsInset,
            bottomBarContent: {
                VStack(spacing: DesignConstants.Spacing.step3x) {
                    if showPullToAddAgent {
                        PullToAddAgentView(
                            overscrollAmount: scrollOverscrollAmount,
                            didReleasePastThreshold: didReleasePastThreshold,
                            onTriggered: {
                                viewModel.onRequestAgentJoin()
                            }
                        )
                        .fixedSize()
                        .frame(height: 0, alignment: .bottom)
                        .allowsHitTesting(false)
                    }

                    bottomBarContent()

                    Group {
                        if viewModel.showsCapabilityApprovedToast {
                            CapabilityApprovedToastView()
                                .transition(.blurReplace)
                        } else if let layout = viewModel.pendingCapabilityPickerLayout {
                            CapabilityPickerCardView(
                                layout: layout,
                                agentName: viewModel.askerDisplayName(for: layout.request),
                                onApprove: { providerIds in
                                    viewModel.onCapabilityApprove(providerIds: providerIds)
                                },
                                onDeny: {
                                    viewModel.onCapabilityDeny()
                                },
                                onConnect: { providerId in
                                    viewModel.onCapabilityConnect(providerId: providerId)
                                }
                            )
                            .transition(.blurReplace)
                        } else {
                            ConversationOnboardingView(
                                coordinator: onboardingCoordinator,
                                focusCoordinator: focusCoordinator,
                                scrollOverscrollAmount: scrollOverscrollAmount,
                                onTapSetupProfile: {
                                    onboardingCoordinator.didTapProfilePhoto()
                                    viewModel.onProfilePhotoTap(focusCoordinator: focusCoordinator)
                                },
                                onUseProfile: viewModel.onUseProfile(_:_:),
                                onPresentProfileSettings: viewModel.onProfileSettings
                            )
                            .transition(.blurReplace)
                        }
                    }
                    .animation(.spring(duration: 0.4, bounce: 0.2), value: viewModel.pendingCapabilityPickerLayout)
                    .animation(.spring(duration: 0.4, bounce: 0.2), value: viewModel.showsCapabilityApprovedToast)
                }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
            }
        )
    }

    @ToolbarContentBuilder
    private var topBarTrailing: some ToolbarContent {
        if !topBarTrailingHidden {
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.isLocked {
                    lockedInfoButton
                } else {
                    switch messagesTopBarTrailingItem {
                    case .share: addToConversationMenu
                    case .scan: scanInviteButton
                    }
                }
            }
        }
    }

    private var lockedInfoButton: some View {
        Button {
            showingLockedInfo = true
        } label: {
            Image(systemName: "lock.fill")
                .foregroundStyle(.colorTextSecondary)
        }
        .accessibilityLabel("Conversation locked")
        .accessibilityHint("Tap for lock details")
        .accessibilityIdentifier("lock-info-button")
    }

    private var addToConversationMenu: some View {
        AddToConversationMenu(
            isFull: viewModel.isFull,
            hasAgent: viewModel.conversation.hasAgent,
            isAgentJoinPending: viewModel.isAgentJoinPending,
            isEnabled: messagesTopBarTrailingItemEnabled && !isReadOnly,
            onConvoCode: {
                if viewModel.isFull {
                    showingFullInfo = true
                } else {
                    viewModel.presentingShareView = true
                }
            },
            onCopyLink: {
                viewModel.copyInviteLink()
            },
            onInviteAgent: {
                viewModel.onRequestAgentJoin()
            },
            onAddFromContacts: handleAddFromContactsTap
        )
    }

    private var handleAddFromContactsTap: () -> Void {
        { presentingAddFromContactsPicker = true }
    }

    @ViewBuilder
    private func memberContactDetailSheet(for member: ConversationMember) -> some View {
        MemberContactDetailSheetContent(viewModel: viewModel, member: member, profileSettingsViewModel: profileSettingsViewModel)
    }

    private var scanInviteButton: some View {
        Button {
            onScanInviteCode()
        } label: {
            Image(systemName: "viewfinder")
        }
        .buttonBorderShape(.circle)
        .disabled(!messagesTopBarTrailingItemEnabled || isReadOnly)
        .accessibilityLabel("Scan invite code")
        .accessibilityIdentifier("scan-invite-button")
    }

    private var debugAttachmentTapHandler: (() -> Void)? {
        guard FeatureFlags.shared.isDebugInjectorEnabled else { return nil }
        return { showingDebugInjector = true }
    }

    private var debugInjectorBinding: Binding<Bool> {
        guard FeatureFlags.shared.isDebugInjectorEnabled else { return .constant(false) }
        return $showingDebugInjector
    }

    private var stuffPage: some View {
        AgentFilesLinksView(
            conversationId: viewModel.conversation.id,
            repository: viewModel.makeAgentFilesLinksRepository(),
            members: viewModel.conversation.members,
            usesInlineHeader: true,
            profileSheetContent: profileSheetForMember,
            focusBinding: $focusState
        )
    }

    private func profileSheetForMember(_ member: ConversationMember) -> AnyView {
        AnyView(MemberContactDetailSheetContent(viewModel: viewModel, member: member, profileSettingsViewModel: profileSettingsViewModel))
    }

    private var pagerDotsInset: CGFloat {
        isKeyboardVisible ? 0.0 : 24.0
    }

    var body: some View {
        let contextMenuPresented: Bool = contextMenuState.isPresented
        ConversationPager(
            selectedPage: $pagerSelectedPage,
            showsPageDots: !isKeyboardVisible,
            dotsHidden: contextMenuPresented,
            scrollingDisabled: contextMenuPresented,
            messagesPage: { messagesView },
            stuffPage: { stuffPage }
        )
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onChange(of: pagerSelectedPage) { _, newPage in
            if newPage != .stuff {
                focusCoordinator.dismissStuffSearchIfNeeded()
            }
        }
        .onChange(of: viewModel.messageText) { _, _ in
            viewModel.checkForInviteURL()
            viewModel.checkForPastedLink()
        }
        .animation(.easeOut, value: viewModel.explodeState)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onAppear { viewModel.onConversationAppeared() }
        .onDisappear {
            focusCoordinator.dismissStuffSearchIfNeeded()
            viewModel.onConversationDisappeared()
        }
        .selfSizingSheet(isPresented: $viewModel.presentingConversationForked) {
            ConversationForkedInfoView {
                viewModel.leaveConvo()
            }
        }
        .sheet(isPresented: $viewModel.presentingProfileSettings) {
            MyInfoView(
                profile: .constant(viewModel.myProfileViewModel.profile),
                profileImage: $viewModel.myProfileViewModel.profileImage,
                editingDisplayName: $viewModel.myProfileViewModel.editingDisplayName,
                profileSettingsViewModel: profileSettingsViewModel,
                showsCancelButton: true,
                showsProfile: true,
                showsUseProfileButton: true,
                canEditProfile: false
            ) { profileSettings in
                viewModel.onUseProfile(profileSettings.profile, profileSettings.profileImage)
            }
            .onDisappear {
                viewModel.onProfileSettingsDismissed(focusCoordinator: focusCoordinator)
            }
        }
        .toolbar { topBarTrailing }
        .debugConnectionInjectorSheet(
            isPresented: debugInjectorBinding,
            conversationId: viewModel.conversation.id,
            messagingService: viewModel.messagingService
        )
        .onReceive(NotificationCenter.default.publisher(for: .requestAddFromContactsInCurrentConversation)) { _ in
            // Surfaces from `NewConvoIdentityView`'s invite-members menu in
            // the new-conversation flow. Reuses the same picker state the
            // chat plus-menu's "Add from Contacts" row drives.
            presentingAddFromContactsPicker = true
        }
        .addFromContactsPicker(
            viewModel: viewModel,
            isPresented: $presentingAddFromContactsPicker
        )
        .sheet(item: $viewModel.presentingNewConversationForInvite) { viewModel in
            NewConversationView(
                viewModel: viewModel,
                profileSettingsViewModel: profileSettingsViewModel
            )
            .background(.colorBackgroundSurfaceless)
        }
        .selfSizingSheet(isPresented: $viewModel.presentingExplodedInviteInfo) {
            ExplodeInfoView()
        }
        .selfSizingSheet(isPresented: $viewModel.presentingAgentConfirmation) {
            AgentsInfoView(
                isConfirmation: true,
                onConfirm: { viewModel.requestAgentJoin() }
            )
            .padding(.top, 20)
        }
        .sheet(isPresented: $viewModel.presentingPaywall) {
            let paywallViewModel = PaywallViewModel(subscriptionService: SubscriptionServices.shared)
            PaywallView(viewModel: paywallViewModel)
        }
        .selfSizingSheet(isPresented: $showingAgentsInfo) {
            AgentsInfoView()
                .padding(.top, 20)
        }
        .sheet(item: $viewModel.presentingProfileForMember) { member in
            memberContactDetailSheet(for: member)
        }
        .selfSizingSheet(item: $viewModel.presentingReactionsForMessage) { message in
            ReactionsDrawerView(message: message) { reaction in
                viewModel.removeReaction(reaction, from: message)
            }
        }
        .selfSizingSheet(item: $viewModel.presentingReadByForGroup) { group in
            ReadByDrawerView(members: group.readByMembers)
        }
        .sheet(item: $viewModel.presentingThinkingDetail) { descriptor in
            ThinkingDetailView(
                descriptor: descriptor,
                conversation: viewModel.conversation,
                viewModel: viewModel,
                profileSheetForMember: profileSheetForMember
            )
        }
        .selfSizingSheet(isPresented: $showingLockedInfo) {
            LockedConvoInfoView(
                isCurrentUserSuperAdmin: viewModel.isCurrentUserSuperAdmin,
                isLocked: viewModel.isLocked,
                onLock: {
                    viewModel.toggleLock()
                    showingLockedInfo = false
                },
                onDismiss: {
                    showingLockedInfo = false
                }
            )
        }
        .selfSizingSheet(isPresented: $showingFullInfo) {
            FullConvoInfoView(onDismiss: {
                showingFullInfo = false
            })
        }
        .selfSizingSheet(
            isPresented: $viewModel.presentingRevealMediaInfoSheet,
            onDismiss: { viewModel.showRevealSettingsToast() },
            content: {
                RevealMediaInfoSheet()
            }
        )
        .selfSizingSheet(
            isPresented: $viewModel.presentingPhotosInfoSheet,
            onDismiss: { focusCoordinator.moveFocus(to: .message) },
            content: {
                PhotosInfoSheet()
            }
        )
        .onDisappear {
            VoiceMemoPlayer.shared.stop()
            viewModel.voiceMemoRecorder.cancelRecording()
        }
    }
}

@MainActor
private func makeConversationViewPreviewViewModel() -> ConversationViewModel {
    .mock
}

struct MemberContactDetailSheetContent: View {
    let viewModel: ConversationViewModel
    let member: ConversationMember
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        let messagingService = viewModel.messagingService
        let contactsRepository = messagingService.contactsRepository()
        let agentTemplateContactsRepository = messagingService.agentTemplateContactsRepository()
        let contactsWriter = messagingService.contactsWriter()
        let resolvedContact = Contact.resolved(
            member: member,
            in: viewModel.conversation.id,
            contactsRepository: contactsRepository
        )
        let onRemove: () -> Void = {
            viewModel.remove(member: member)
            dismiss()
        }
        NavigationStack {
            ContactDetailView(
                contact: resolvedContact,
                mode: .scopedToConversation(
                    conversationId: viewModel.conversation.id,
                    canRemoveMembers: viewModel.canRemoveMembers,
                    isCurrentUser: member.isCurrentUser,
                    invitedBy: member.invitedBy,
                    joinedAt: member.joinedAt
                ),
                contactsWriter: contactsWriter,
                contactsRepository: contactsRepository,
                agentTemplateContactsRepository: agentTemplateContactsRepository,
                session: viewModel.session,
                profileSettingsViewModel: profileSettingsViewModel,
                onRemove: onRemove
            )
        }
    }
}

#Preview {
    @Previewable @State var viewModel: ConversationViewModel = makeConversationViewPreviewViewModel()
    @Previewable @State var profileSettingsViewModel: ProfileSettingsViewModel = .shared
    @Previewable @FocusState var focusState: MessagesViewInputFocus?
    @Previewable @State var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    NavigationStack {
        ConversationView(
            viewModel: viewModel,
            profileSettingsViewModel: profileSettingsViewModel,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            onScanInviteCode: {},
            onDeleteConversation: {},
            messagesTopBarTrailingItem: .share,
            messagesTopBarTrailingItemEnabled: true,
            messagesTextFieldEnabled: true,
            bottomBarContent: { EmptyView() }
        )
    }
}
