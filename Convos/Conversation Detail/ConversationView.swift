import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
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
    @State private var pagerSelectedPage: ConversationPagerPage = .messages
    @State private var isKeyboardVisible: Bool = false
    /// Lifted out of `MessagesView` so this view can gate the pager
    /// against horizontal swipes while the long-press context menu is
    /// presented.
    @State private var contextMenuState: MessageContextMenuState = .init()
    @State private var showingDebugInjector: Bool = false
    @State private var presentingAddFromContactsPicker: Bool = false
    @State private var navState: ConversationNavigatorImpl = .init()
    @State private var navigator: ConversationCollector?
    @Environment(\.dismiss) private var dismiss: DismissAction

    /// Read-only when the presenter asks for it (stale/removed device) or
    /// when the local user was removed from this conversation but can still
    /// view it (e.g. it was open when the removal landed).
    private var effectiveReadOnly: Bool {
        isReadOnly || viewModel.conversation.wasRemoved
    }

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = ConversationCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    private var conversationIdForMetrics: String {
        viewModel.conversation.id
    }

    private func handleConversationSettingsChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(conversationInfo: ConversationInfoNavigatorArgs(conversationId: conversationIdForMetrics))
    }

    private func handleProfileSettingsChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(myInfo: MyInfoNavigatorArgs())
    }

    private func handleShareViewChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(shareInvite: ShareInviteNavigatorArgs(conversationId: conversationIdForMetrics))
    }

    private func handleConversationForkedChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(conversationForkedInfo: ConversationForkedInfoNavigatorArgs(conversationId: conversationIdForMetrics))
    }

    private func handleExplodedInviteInfoChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(explodedInviteInfo: ExplodedInviteInfoNavigatorArgs())
    }

    private func handleAgentsIntroChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(assistantConfirmation: AssistantConfirmationNavigatorArgs(conversationId: conversationIdForMetrics))
    }

    private func handlePaywallChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(paywall: PaywallNavigatorArgs(source: .lowBalanceBanner))
    }

    private func handleAgentsInfoChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(agentInfo: AgentInfoNavigatorArgs())
    }

    private func handleLockedInfoChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(lockedConvoInfo: LockedConvoInfoNavigatorArgs(conversationId: conversationIdForMetrics))
    }

    private func handleFullInfoChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(fullConvoInfo: FullConvoInfoNavigatorArgs())
    }

    private func handleRevealMediaInfoChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(revealMediaInfo: RevealMediaInfoNavigatorArgs())
    }

    private func handlePhotosInfoChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(photosInfo: PhotosInfoNavigatorArgs())
    }

    private func handleAgentBuilderChanged(from wasPresenting: Bool, to isPresenting: Bool) {
        guard !wasPresenting, isPresenting else { return }
        navigator?.present(agentBuilder: AgentBuilderNavigatorArgs(conversationId: conversationIdForMetrics, entryMode: .sheet))
    }

    private func handleNewConvoInviteChanged(from wasPresenting: Bool, to isPresenting: Bool) {
        guard !wasPresenting, isPresenting else { return }
        navigator?.present(newConversation: NewConversationNavigatorArgs(mode: .joinInvite))
    }

    /// The agent-share placeholder card reports as a member-profile present
    /// with the placeholder's sentinel inbox id (`agent-share:<templateId>`),
    /// keeping "a profile card opened from this conversation" consistent in
    /// analytics with the member-avatar path while staying distinguishable.
    private func handleAgentShareContactChanged(from oldContact: Contact?, to newContact: Contact?) {
        guard oldContact == nil, let newContact else { return }
        navigator?.present(
            memberProfile: MemberProfileNavigatorArgs(
                conversationId: conversationIdForMetrics,
                memberId: newContact.inboxId
            )
        )
    }

    private func handleMemberProfileChanged(from oldMember: ConversationMember?, to newMember: ConversationMember?) {
        guard oldMember == nil, let newMember else { return }
        navigator?.present(
            memberProfile: MemberProfileNavigatorArgs(
                conversationId: conversationIdForMetrics,
                memberId: newMember.profile.inboxId
            )
        )
    }

    private func handleReactionsChanged(from oldMessage: AnyMessage?, to newMessage: AnyMessage?) {
        guard oldMessage == nil, let newMessage else { return }
        navigator?.present(
            reactions: ReactionsNavigatorArgs(
                conversationId: conversationIdForMetrics,
                messageId: newMessage.id
            )
        )
    }

    private func handleThinkingDetailChanged(from oldValue: ThinkingSessionDescriptor?, to newValue: ThinkingSessionDescriptor?) {
        guard oldValue == nil, let newValue else { return }
        navigator?.present(
            thinkingDetail: ThinkingDetailNavigatorArgs(
                conversationId: conversationIdForMetrics,
                senderInboxId: newValue.sender.profile.inboxId,
                messageId: newValue.targetMessageId
            )
        )
    }

    private func handleAddFromContactsChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(
            addMembers: AddMembersNavigatorArgs(
                conversationId: conversationIdForMetrics,
                conversationTitle: viewModel.conversation.name
            )
        )
    }

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
            pendingInviteIsEditable: viewModel.pendingInvite?.linkedConversationId != nil,
            pendingInviteEmoji: viewModel.conversation.conversationEmoji,
            pendingInviteConvoName: $viewModel.pendingInviteConvoName,
            pendingInviteImage: $viewModel.pendingInviteImage,
            pendingInviteExplodeDuration: viewModel.pendingInvite?.explodeDuration,
            onSetInviteExplodeDuration: { duration in viewModel.setInviteExplodeDuration(duration) },
            onInviteConvoNameEditingEnded: { name in
                viewModel.updateLinkedConversationName(name)
                focusCoordinator.endEditing(for: .sideConvoName, context: .quickEditor)
            },
            pendingAgentShareName: viewModel.pendingAgentShare?.resolved?.displayName,
            pendingAgentShareEmoji: viewModel.pendingAgentShare?.resolved?.emoji,
            pendingAgentShareSummary: viewModel.pendingAgentShare?.resolved?.descriptionText,
            isShowingAgentShareChip: viewModel.pendingAgentShare != nil,
            onClearAgentShare: viewModel.clearPendingAgentShare,
            sendButtonEnabled: viewModel.sendButtonEnabled,
            profileImage: $viewModel.myProfileViewModel.profileImage,
            onboardingCoordinator: onboardingCoordinator,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            messagesTextFieldEnabled: messagesTextFieldEnabled,
            isReadOnly: effectiveReadOnly,
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
            onTapAgentShare: viewModel.onTapAgentShare(_:),
            agentShareResolver: viewModel.agentShareResolver,
            inviteMembershipResolver: viewModel.inviteMembershipResolver,
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
            onTapCapabilityConnect: { prompt in
                // Read-only viewers see the pill but can't answer the request
                // (a result message couldn't be sent on their behalf anyway).
                guard !effectiveReadOnly else { return }
                viewModel.onTapCapabilityConnectPrompt(prompt)
            },
            onRetryMessage: viewModel.retryMessage(_:),
            onDeleteMessage: viewModel.deleteMessage(_:),
            onRetryAgentJoin: { viewModel.retryAgentJoin() },
            onCopyInviteLink: { viewModel.copyInviteLink() },
            onConvoCode: {
                if viewModel.isFull {
                    showingFullInfo = true
                } else {
                    viewModel.presentingShareView = true
                }
            },
            onInviteAgent: { viewModel.presentAgentBuilder() },
            onRetryTranscript: { item in
                viewModel.retryTranscript(for: item)
            },
            profileSheetForMember: profileSheetForMember,
            memberContactOverride: contactOverride,
            isAgentJoinPending: viewModel.isAgentJoinPending,
            headerMode: effectiveReadOnly ? .suppressed : headerMode,
            agentBuilderSummary: viewModel.agentBuilderSummary,
            agentBuilderTransitionNamespace: agentBuilderTransitionNamespace,
            onVoiceMemoTap: { viewModel.onVoiceMemoTapped() },
            voiceMemoRecorder: viewModel.voiceMemoRecorder,
            onSendVoiceMemo: { viewModel.sendVoiceMemo() },
            onConvosAction: { viewModel.onConvosButtonTapped() },
            onDebugAttachmentTap: debugAttachmentTapHandler,
            extraBottomInset: pagerDotsInset,
            bottomBarContent: {
                VStack(spacing: DesignConstants.Spacing.step3x) {
                    bottomBarContent()

                    // Capability requests no longer auto-present a card here:
                    // the transcript's connect pill is the single entry point
                    // and opens the approval sheet. The slot keeps the
                    // post-approval toast and the onboarding view.
                    Group {
                        if viewModel.showsCapabilityApprovedToast {
                            CapabilityApprovedToastView()
                                .transition(.blurReplace)
                        } else {
                            ConversationOnboardingView(
                                coordinator: onboardingCoordinator,
                                focusCoordinator: focusCoordinator,
                                onTapSetupProfile: {
                                    onboardingCoordinator.didTapProfilePhoto()
                                    viewModel.onProfilePhotoTap(focusCoordinator: focusCoordinator)
                                },
                                onUseProfile: viewModel.onUseProfile(_:_:),
                                onPresentProfileSettings: viewModel.onProfileSettings,
                                coreActions: viewModel.coreActions
                            )
                            .transition(.blurReplace)
                        }
                    }
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
            isAgentJoinPending: viewModel.isAgentJoinPending,
            isEnabled: messagesTopBarTrailingItemEnabled && !effectiveReadOnly,
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
                viewModel.presentAgentBuilder()
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

    @ViewBuilder
    private func agentShareContactDetailSheet(for contact: Contact) -> some View {
        AgentShareContactDetailSheetContent(viewModel: viewModel, contact: contact, profileSettingsViewModel: profileSettingsViewModel)
    }

    private var scanInviteButton: some View {
        Button {
            onScanInviteCode()
        } label: {
            Image(systemName: "viewfinder")
        }
        .buttonBorderShape(.circle)
        .disabled(!messagesTopBarTrailingItemEnabled || effectiveReadOnly)
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

    private var thingsPage: some View {
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

    /// Approval sheet for the pending capability request, opened from the
    /// transcript's connect pill. Extracted to keep `body`'s type-check time
    /// in budget. The layout can clear while the sheet is up (another device
    /// resolved the request) — the view model auto-dismisses in that case and
    /// the EmptyView only covers the dismissal animation frame.
    @ViewBuilder
    private var capabilityApprovalSheet: some View {
        if let layout = viewModel.pendingCapabilityPickerLayout {
            CapabilityApprovalSheetView(
                layout: layout,
                agentName: viewModel.askerDisplayName(for: layout.request),
                onApprove: { providerIds, bundleSelection in
                    viewModel.onCapabilityApprove(
                        providerIds: providerIds,
                        bundleSelection: bundleSelection
                    )
                }
            )
        } else {
            EmptyView()
        }
    }

    /// Shared content for the invite- and agent-share-driven new-conversation
    /// sheets. Extracted so neither `.sheet(item:)` closure inflates `body`'s
    /// type-check past the 300ms budget.
    @ViewBuilder
    private func newConversationSheet(_ viewModel: NewConversationViewModel) -> some View {
        NewConversationView(
            viewModel: viewModel,
            profileSettingsViewModel: profileSettingsViewModel
        )
        .background(.colorBackgroundSurfaceless)
    }

    private var pagerDotsInset: CGFloat {
        isKeyboardVisible ? 0.0 : 24.0
    }

    private var metricsObserversPart1: MetricsObserversPart1 {
        MetricsObserversPart1(
            presentingConversationSettings: viewModel.presentingConversationSettings,
            presentingProfileSettings: viewModel.presentingProfileSettings,
            presentingShareView: viewModel.presentingShareView,
            presentingConversationForked: viewModel.presentingConversationForked,
            presentingExplodedInviteInfo: viewModel.presentingExplodedInviteInfo,
            presentingAgentsIntro: viewModel.presentingAgentsIntro,
            presentingPaywall: viewModel.presentingPaywall,
            showingAgentsInfo: showingAgentsInfo,
            showingLockedInfo: showingLockedInfo,
            onConversationSettingsChanged: handleConversationSettingsChanged(from:to:),
            onProfileSettingsChanged: handleProfileSettingsChanged(from:to:),
            onShareViewChanged: handleShareViewChanged(from:to:),
            onConversationForkedChanged: handleConversationForkedChanged(from:to:),
            onExplodedInviteInfoChanged: handleExplodedInviteInfoChanged(from:to:),
            onAgentsIntroChanged: handleAgentsIntroChanged(from:to:),
            onPaywallChanged: handlePaywallChanged(from:to:),
            onAgentsInfoChanged: handleAgentsInfoChanged(from:to:),
            onLockedInfoChanged: handleLockedInfoChanged(from:to:)
        )
    }

    private var metricsObserversPart3: MetricsObserversPart3 {
        MetricsObserversPart3(
            presentingProfileForMember: viewModel.presentingProfileForMember,
            presentingContactForAgentShare: viewModel.presentingContactForAgentShare,
            presentingReactionsForMessage: viewModel.presentingReactionsForMessage,
            presentingThinkingDetail: viewModel.presentingThinkingDetail,
            onMemberProfileChanged: handleMemberProfileChanged(from:to:),
            onAgentShareContactChanged: handleAgentShareContactChanged(from:to:),
            onReactionsChanged: handleReactionsChanged(from:to:),
            onThinkingDetailChanged: handleThinkingDetailChanged(from:to:)
        )
    }

    private var metricsObserversPart2: MetricsObserversPart2 {
        MetricsObserversPart2(
            showingFullInfo: showingFullInfo,
            presentingRevealMediaInfo: viewModel.presentingRevealMediaInfoSheet,
            presentingPhotosInfo: viewModel.presentingPhotosInfoSheet,
            presentingAgentBuilder: viewModel.presentingAgentBuilder != nil,
            presentingNewConvoForInvite: viewModel.presentingNewConversationForInvite != nil,
            presentingAddFromContactsPicker: presentingAddFromContactsPicker,
            onFullInfoChanged: handleFullInfoChanged(from:to:),
            onRevealMediaInfoChanged: handleRevealMediaInfoChanged(from:to:),
            onPhotosInfoChanged: handlePhotosInfoChanged(from:to:),
            onAgentBuilderChanged: handleAgentBuilderChanged(from:to:),
            onNewConvoInviteChanged: handleNewConvoInviteChanged(from:to:),
            onAddFromContactsChanged: handleAddFromContactsChanged(from:to:)
        )
    }

    var body: some View {
        let contextMenuPresented: Bool = contextMenuState.isPresented
        ConversationPager(
            selectedPage: $pagerSelectedPage,
            showsPageDots: !isKeyboardVisible,
            dotsHidden: contextMenuPresented,
            scrollingDisabled: contextMenuPresented,
            messagesPage: { messagesView },
            thingsPage: { thingsPage }
        )
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onChange(of: pagerSelectedPage) { _, newPage in
            if newPage != .things {
                focusCoordinator.dismissThingsSearchIfNeeded()
            }
        }
        .onChange(of: viewModel.messageText) { _, _ in
            viewModel.checkForInviteURL()
            viewModel.checkForAgentShareURL()
            viewModel.checkForPastedLink()
        }
        .animation(.easeOut, value: viewModel.explodeState)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onAppear {
            ensureNavigator()
            navState.markScreenAppeared()
            viewModel.onConversationAppeared()
        }
        .onDisappear {
            focusCoordinator.dismissThingsSearchIfNeeded()
            viewModel.onConversationDisappeared()
            navigator?.closed(context: navState.closeContext())
        }
        .modifier(metricsObserversPart1)
        .modifier(metricsObserversPart2)
        .modifier(metricsObserversPart3)
        .selfSizingSheet(isPresented: $viewModel.presentingConversationForked) {
            ConversationForkedInfoView {
                viewModel.leaveConvo()
            }
        }
        .selfSizingSheet(isPresented: $viewModel.presentingCapabilityApproval) {
            capabilityApprovalSheet
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
            newConversationSheet(viewModel)
        }
        .sheet(item: $viewModel.presentingContactForAgentShare) { contact in
            agentShareContactDetailSheet(for: contact)
        }
        .selfSizingSheet(isPresented: $viewModel.presentingExplodedInviteInfo) {
            ExplodeInfoView()
        }
        .sheet(item: $viewModel.presentingAgentBuilder) { builderViewModel in
            AgentBuilderView(
                viewModel: builderViewModel,
                profileSettingsViewModel: profileSettingsViewModel
            )
        }
        .selfSizingSheet(isPresented: $viewModel.presentingAgentsIntro, onDismiss: {
            viewModel.presentAgentBuilderAfterIntroIfNeeded()
        }, content: {
            AgentsInfoView(onMakeAgent: { viewModel.pendingAgentBuilderAfterIntro = true })
                .padding(.top, 20)
        })
        .sheet(isPresented: $viewModel.presentingPaywall) {
            let paywallViewModel = PaywallViewModel(
                subscriptionService: SubscriptionServices.shared,
                paywallSource: .lowBalanceBanner,
                coreActions: viewModel.coreActions
            )
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
                session: viewModel.session,
                coreActions: viewModel.coreActions,
                profileSettingsViewModel: profileSettingsViewModel,
                onRemove: onRemove
            )
        }
    }
}

/// Contact detail sheet for a tapped agent-share message card whose template
/// has no running agent in this conversation. The contact is a placeholder
/// built from the share link's resolved profile (see
/// `Contact.agentSharePlaceholder`), so the card renders in `.standalone`
/// mode: no "Remove from convo", and the unsaved-placeholder gating hides
/// the "Added X ago" line and Block. "New chat" spawns a fresh instance of
/// the template via the card's own confirmation flow.
struct AgentShareContactDetailSheetContent: View {
    let viewModel: ConversationViewModel
    let contact: Contact
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel

    var body: some View {
        let messagingService = viewModel.messagingService
        NavigationStack {
            ContactDetailView(
                contact: contact,
                contactsWriter: messagingService.contactsWriter(),
                contactsRepository: messagingService.contactsRepository(),
                session: viewModel.session,
                coreActions: viewModel.coreActions,
                profileSettingsViewModel: profileSettingsViewModel
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
