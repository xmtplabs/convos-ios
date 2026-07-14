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
    /// Set by the "Show an invite code" new-convo flow. When true, the chat
    /// pins the shared `InviteCodeBody` (Scan/Invite segmented toggle) as a top
    /// `safeAreaInset`, suppresses the duplicate message-list-header QR, and
    /// drops the lone scan toolbar item (the Scan segment owns scanning). The
    /// Scan segment routes decoded codes to `onScannedInviteCode`, opening a
    /// brand-new convo rather than scanning into this one.
    var showsEmbeddedInvite: Bool = false
    /// Segment the embedded Scan/Invite toggle starts on. The home scan entry
    /// passes `.scan`; "Show an invite code" and normal convos keep `.invite`.
    var embeddedInviteInitialSegment: ScanInviteSegment = .invite
    /// Routes a code decoded by the embedded Scan segment to the new-convo join
    /// path. Nil keeps the embedded viewfinder decode-only.
    var onScannedInviteCode: ((String) -> Void)?
    /// Fires when the embedded invite's "Share invite link" completes, so the
    /// backing new-convo flow can mark its invite as shared and skip the
    /// empty-conversation teardown that would otherwise break the shared link.
    var onInviteShared: (() -> Void)?
    /// Shared SwiftUI namespace used by the Agent Builder commit morph.
    /// Set by `AgentBuilderView` so its composer card and the in-stream
    /// summary cell can match-geometry into each other via `glassEffectID`.
    var agentBuilderTransitionNamespace: Namespace.ID?
    @ViewBuilder let bottomBarContent: () -> MessagesBottomBar

    @State private var showingLockedInfo: Bool = false
    @State private var showingFullInfo: Bool = false
    @State private var showingAgentsInfo: Bool = false
    @State private var pagerSelectedPage: ConversationPagerPage = .messages
    /// Tracks keyboard visibility so the pager dots hide and the pager-dots
    /// inset collapses while the keyboard is up.
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
        // Moving into the Scan/Invite overlay must leave the keyboard down.
        // The composer's first responder lives across the messages view
        // controller's UIKit boundary, so clear both layers: the coordinator
        // (so no focus-restore logic re-raises it) and the actual first
        // responder. The invite picker sheet additionally re-resigns on its
        // dismissal (see `AddFromContactsPickerModifier`), because UIKit
        // restores the composer's first responder when the sheet finishes
        // dismissing.
        focusCoordinator.moveFocus(to: nil)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
        // Prefer current member profiles over the lagging contacts table so
        // system-message and receipt rows stay in sync with the message bubble.
        Contact.memberAwareResolver(
            members: viewModel.conversation.members,
            contactLookup: viewModel.messagingService.contactsRepository().contact(for:)
        )
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
            onOpenMessageDetail: { message in
                viewModel.presentingMessageDetail = message
            },
            expandedMessageIds: viewModel.expandedMessageIds,
            onToggleMessageExpanded: { messageId in
                viewModel.toggleMessageExpanded(messageId)
            },
            replyingToMessage: viewModel.replyingToMessage,
            replyingToAudioTranscriptText: viewModel.replyingToAudioTranscriptText,
            onCancelReply: viewModel.cancelReply,
            onDisplayNameEndedEditing: {
                viewModel.onDisplayNameEndedEditing(focusCoordinator: focusCoordinator, context: .quickEditor)
            },
            onProfileSettings: viewModel.onProfileSettings,
            onLoadPreviousMessages: viewModel.loadPreviousMessages,
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
            headerMode: effectiveHeaderMode,
            agentBuilderSummary: viewModel.agentBuilderSummary,
            agentBuilderTransitionNamespace: agentBuilderTransitionNamespace,
            onVoiceMemoTap: { viewModel.onVoiceMemoTapped() },
            voiceMemoRecorder: viewModel.voiceMemoRecorder,
            onSendVoiceMemo: { viewModel.sendVoiceMemo() },
            onDebugAttachmentTap: debugAttachmentTapHandler,
            extraBottomInset: pagerDotsInset,
            showsInviteScanCard: showsTopOfConvoInvite,
            inviteScanMode: inviteScanMode,
            inviteScanInitialSegment: embeddedInviteInitialSegment,
            onScannedInviteCode: inviteScanScannedHandler,
            onInviteShareCompleted: onInviteShareCompletedHandler,
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
        // The embedded Scan/Invite toggle owns scanning, so the lone viewfinder
        // toolbar item is dropped for that flow.
        if !topBarTrailingHidden && !showsEmbeddedInvite {
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.isLocked {
                    lockedInfoButton
                } else {
                    switch messagesTopBarTrailingItem {
                    case .share:
                        // A full conversation can't mint new invite links, so the
                        // invite affordance is hidden entirely (mirrors
                        // `showsTopOfConvoInvite`'s `!isFull` gate).
                        if !viewModel.isFull {
                            inviteButton
                        }
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

    /// The in-conversation top-right invite affordance. Opens the "Invite"
    /// sheet (Figma node 5562-34019): the contacts picker re-titled "Invite",
    /// scoped to this conversation, carrying the three convo-scoped invite
    /// action rows + the scanner. Replaces the former `AddToConversationMenu`
    /// context menu; the sheet itself is presented by `.addFromContactsPicker`.
    private var inviteButton: some View {
        Button(action: handleAddFromContactsTap) {
            Image(systemName: "person.crop.circle.badge.plus")
        }
        .disabled(!messagesTopBarTrailingItemEnabled || effectiveReadOnly)
        .accessibilityLabel("Invite")
        .accessibilityIdentifier("add-to-conversation-button")
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

    var body: some View {
        ConversationPager(
            selectedPage: $pagerSelectedPage,
            showsPageDots: !isKeyboardVisible,
            dotsHidden: contextMenuState.isPresented,
            scrollingDisabled: contextMenuState.isPresented,
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
            // ProfileSetupSheet owns the full save; no dismiss handler —
            // the old onProfileSettingsDismissed re-saved from the stale
            // myProfileViewModel and clobbered the just-saved profile.
            ProfileSetupSheet(mode: .edit)
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
            isPresented: $presentingAddFromContactsPicker,
            onInviteShared: onInviteShared
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
        .sheet(item: $viewModel.presentingAgentBuilder, onDismiss: {
            // Coming out of the in-chat maker, don't reopen the conversation
            // keyboard: the agent still has to build and join before anything
            // can be sent, so landing back here with the input focused isn't
            // useful. Clear focus instead of letting it restore to `.message`.
            focusCoordinator.moveFocus(to: nil)
        }, content: { builderViewModel in
            AgentBuilderView(
                viewModel: builderViewModel,
                profileSettingsViewModel: profileSettingsViewModel
            )
        })
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
            ReadByDrawerView(
                members: group.readByMembers,
                memberContactOverride: contactOverride
            )
        }
        .sheet(item: $viewModel.presentingThinkingDetail) { descriptor in
            ThinkingDetailView(
                descriptor: descriptor,
                conversation: viewModel.conversation,
                viewModel: viewModel,
                profileSheetForMember: profileSheetForMember
            )
        }
        .sheet(item: $viewModel.presentingMessageDetail) { message in
            MessageDetailView(
                message: message,
                onCopy: { text in
                    UIPasteboard.general.string = text
                },
                onReply: { repliedMessage in
                    viewModel.presentingMessageDetail = nil
                    viewModel.onReply(repliedMessage)
                    focusCoordinator.moveFocus(to: .message)
                }
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
                variantStamp: member.profile.variant,
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

extension ConversationView {
    /// Read-only when the presenter asks for it (stale/removed device) or
    /// when the local user was removed from this conversation but can still
    /// view it (e.g. it was open when the removal landed).
    private var effectiveReadOnly: Bool {
        isReadOnly || viewModel.conversation.wasRemoved
    }

    /// The embedded Scan/Invite toggle is the universal top-of-convo invite UI.
    /// It shows above the chat for every conversation that meets the same
    /// eligibility the legacy message-list QR header used (you created it, it's
    /// not locked, it's not full), for the whole active invite session: from
    /// first entry, through joins and incoming messages, until the host
    /// navigates back to home and returns (tracked by the persisted
    /// `leftHostedInviteSession` flag). App-backgrounding does not end the
    /// session. The "Show an invite code" new-convo flow shows it
    /// unconditionally. The Agent Builder draft (`headerMode == .hidden`) and
    /// read-only surfaces opt out. When the toggle shows, it owns the QR, so
    /// the duplicate message-list-header QR is suppressed via
    /// `effectiveHeaderMode -> .hidden`.
    var showsTopOfConvoInvite: Bool {
        if showsEmbeddedInvite { return true }
        guard !effectiveReadOnly, headerMode == .standard else { return false }
        let conversation = viewModel.conversation
        guard !conversation.isDraft else { return false }
        return conversation.creator.isCurrentUser && !conversation.isLocked && !conversation.isFull && !conversation.leftHostedInviteSession
    }

    /// Read-only surfaces suppress every leading affordance. The inline
    /// Invite/Scan card now lives in the index-0 `.invite` cell (branched on
    /// `showsInviteScanCard`), so the header no longer forces `.hidden` to
    /// dedupe against a pinned overlay.
    private var effectiveHeaderMode: MessagesHeaderMode {
        effectiveReadOnly ? .suppressed : headerMode
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

extension ConversationView {
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
            presentingPhotosInfo: viewModel.presentingPhotosInfoSheet,
            presentingAgentBuilder: viewModel.presentingAgentBuilder != nil,
            presentingNewConvoForInvite: viewModel.presentingNewConversationForInvite != nil,
            presentingAddFromContactsPicker: presentingAddFromContactsPicker,
            onFullInfoChanged: handleFullInfoChanged(from:to:),
            onPhotosInfoChanged: handlePhotosInfoChanged(from:to:),
            onAgentBuilderChanged: handleAgentBuilderChanged(from:to:),
            onNewConvoInviteChanged: handleNewConvoInviteChanged(from:to:),
            onAddFromContactsChanged: handleAddFromContactsChanged(from:to:)
        )
    }
}
