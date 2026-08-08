import ConvosComposer
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
    /// When set (and that agent has a DM page), the pager opens on the agent's
    /// DM page instead of the group. Used when a conversations-list row is
    /// tapped whose most-recent unread is in the DM.
    var initialAgentDmInboxId: String?
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
    /// Opt-in for the desktop-mode layout (webview desktop + chat drawer)
    /// behind the desktop feature flag. Only the normal pushed conversation
    /// passes true; the Agent Builder and new-convo hosts never get it.
    var allowsDesktopMode: Bool = false
    @ViewBuilder let bottomBarContent: () -> MessagesBottomBar

    @State private var showingLockedInfo: Bool = false
    @State private var showingFullInfo: Bool = false
    @State private var showingAgentsInfo: Bool = false
    /// Agent participation for this conversation, behind the Listen debug flag.
    /// It lives here rather than in the composer because the level belongs to
    /// the conversation; the composer only draws the control.
    @State private var participation: AgentParticipationStore?
    @State private var pagerSelectedPage: ConversationPagerPage = .messages
    /// Which agent DM the single `.agent` page shows; nil falls back to the
    /// first agent (see `AgentPageView`). New-composer path only.
    @State private var selectedAgentInboxId: String?
    /// Guards the one-time seed of `pagerSelectedPage` from `initialAgentDmInboxId`.
    @State private var didSeedInitialPage: Bool = false
    /// Guards the one-time seed of the desktop drawer's opening detent from the
    /// conversation's unread state.
    @State private var didSeedDrawerDetent: Bool = false
    /// Measured height of the nag-bar slot (capability toast / onboarding),
    /// consumed by the desktop drawer's collapsed resting height so the bar
    /// stays visible above the fold.
    @State private var nagBarHeight: CGFloat = 0
    /// Tracks keyboard visibility so the pager dots hide and the pager-dots
    /// inset collapses while the keyboard is up.
    @State private var isKeyboardVisible: Bool = false
    /// Measured height of the docked keyboard (0 when hidden). The desktop
    /// scroll surface reserves this below its content so the last section
    /// clears the keyboard-raised compose card; the drawer uses only the
    /// visibility flag.
    @State private var keyboardHeight: CGFloat = 0
    /// Exact height of the desktop switcher slot. The transcript uses this
    /// instead of a tuned constant so its last row clears both the switcher
    /// and the keyboard at every content-size category.
    @State private var desktopSwitcherHeight: CGFloat = 0
    /// Lifted out of `MessagesView` so this view can gate the pager
    /// against horizontal swipes while the long-press context menu is
    /// presented.
    @State private var contextMenuState: MessageContextMenuState = .init()
    /// Resting position of the desktop-mode chat drawer. Collapsed is the
    /// entry state: the drawer rests as the compose card with the chat
    /// concealed entirely.
    @State private var drawerDetent: ConversationDrawerDetent = .collapsed
    /// The drawer's live occupied height (keyboard included), reported by the
    /// drawer and fed to the desktop scroll surface so its content insets by
    /// however much the drawer currently covers.
    @State private var drawerHeight: CGFloat = ConversationDrawerMetrics.collapsedRestingHeight
    @State private var showingDebugInjector: Bool = false
    @State private var presentingAddFromContactsPicker: Bool = false
    @State private var navState: ConversationNavigatorImpl = .init()
    @State private var navigator: ConversationCollector?
    @Environment(\.dismiss) private var dismiss: DismissAction
    /// The ambient scheme the desktop drawer returns to when the Agent tab
    /// is not selected (desktop mode scopes the agent dark treatment to the
    /// drawer instead of flipping the whole window).
    @Environment(\.colorScheme) private var systemColorScheme: ColorScheme

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
        // Desktop mode relocates the Scan/Invite card onto the desktop
        // surface, so the transcript's inline card is suppressed there.
        let showsInlineInviteScanCard: Bool = showsTopOfConvoInvite && !isDesktopActive
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
            agentPowerDepletedByInboxId: viewModel.agentPowerDepletedByInboxId,
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
            showsInviteScanCard: showsInlineInviteScanCard,
            suppressesInviteCell: isDesktopActive,
            inviteScanMode: inviteScanMode,
            inviteScanInitialSegment: embeddedInviteInitialSegment,
            onScannedInviteCode: inviteScanScannedHandler,
            onInviteShareCompleted: onInviteShareCompletedHandler,
            bottomBarContent: {
                VStack(spacing: DesignConstants.Spacing.step3x) {
                    bottomBarContent()

                    conversationNagBar(onboardingCoordinator: onboardingCoordinator)
                }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
            }
        )
        // Only where there is an agent to govern, and only while the Listen
        // flag is on. Absent, the composer draws no bubble at all.
        .environment(\.agentParticipation, participationContext)
        .task(id: participationTaskKey) { await prepareParticipation() }
        // The mode rides the group's appData, so another member's change lands
        // as a change to this conversation's synced row and the bubble follows
        // it - nothing here polls.
        .onChange(of: viewModel.conversation.participationMode) { _, mode in
            participation?.apply(syncedLevel: AgentParticipationLevel(mode: mode))
        }
        .alert(
            "Participation not updated",
            isPresented: Binding(
                get: { participation?.errorMessage != nil },
                set: { if !$0 { participation?.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { participation?.dismissError() }
        } message: {
            Text(participation?.errorMessage ?? "Please try again.")
        }
    }

    /// True while the agent-DM page is the pager's selected page. The DM is a
    /// fixed 2-member conversation, so the invite/add-member affordance is hidden
    /// there.
    private var isAgentDmPageActive: Bool {
        if case .agentDm = pagerSelectedPage { return true }
        return pagerSelectedPage == .agent
    }

    /// Opens the pager on the requested agent-DM page once, when the view was
    /// pushed from a conversations-list row whose most-recent unread is a DM.
    /// No-op unless that agent actually has a DM page in this conversation.
    private func seedInitialPageIfNeeded() {
        guard !didSeedInitialPage else { return }
        didSeedInitialPage = true
        guard let inboxId = initialAgentDmInboxId,
              agentDmPageInboxIds.contains(inboxId) else {
            return
        }
        if isNewComposerActive {
            selectedAgentInboxId = inboxId
            pagerSelectedPage = .agent
        } else {
            pagerSelectedPage = .agentDm(agentInboxId: inboxId)
        }
    }

    /// Switches to a specific agent-DM page when a DM notification is tapped while
    /// this conversation is already on screen (a fresh open seeds the page from
    /// `initialAgentDmInboxId`, but re-selecting the same conversation is a no-op,
    /// so an already-open view has to be told directly). Ignores requests for a
    /// different conversation or an agent without a DM page here.
    private func handleSelectAgentDmPageRequest(_ note: Notification) {
        guard let conversationId = note.userInfo?["conversationId"] as? String,
              conversationId == viewModel.conversation.id,
              let agentInboxId = note.userInfo?["agentInboxId"] as? String,
              agentDmPageInboxIds.contains(agentInboxId) else {
            return
        }
        if isNewComposerActive {
            // A selection write alone switches the mounted DM when the user
            // is already on the agent page.
            selectedAgentInboxId = agentInboxId
            pagerSelectedPage = .agent
        } else {
            pagerSelectedPage = .agentDm(agentInboxId: agentInboxId)
        }
    }

    @ToolbarContentBuilder
    private var topBarTrailing: some ToolbarContent {
        // The embedded Scan/Invite toggle owns scanning, so the lone viewfinder
        // toolbar item is dropped for that flow.
        if !topBarTrailingHidden && !showsEmbeddedInvite {
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.isLocked {
                    lockedInfoButton
                } else if !isAgentDmPageActive {
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

    /// Non-nil only for members whose agent has a DM pager page (every
    /// verified agent gets its own segment; anyone else falls back to the
    /// contact card's direct-create path). Hoisted out of the view function
    /// so it stays a single builder expression.
    private func startAgentDmAction(for member: ConversationMember) -> ((String) -> Void)? {
        guard agentDmPageInboxIds.contains(member.profile.inboxId) else { return nil }
        if isNewComposerActive {
            return { agentInboxId in
                viewModel.presentingProfileForMember = nil
                selectedAgentInboxId = agentInboxId
                withAnimation(.easeInOut(duration: 0.25)) {
                    pagerSelectedPage = .agent
                }
            }
        }
        return { agentInboxId in
            viewModel.presentingProfileForMember = nil
            withAnimation(.easeInOut(duration: 0.25)) {
                pagerSelectedPage = .agentDm(agentInboxId: agentInboxId)
            }
        }
    }

    private func memberContactDetailSheet(for member: ConversationMember) -> some View {
        MemberContactDetailSheetContent(
            viewModel: viewModel,
            member: member,
            profileSettingsViewModel: profileSettingsViewModel,
            onStartAgentDm: startAgentDmAction(for: member)
        )
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
    /// resolved the request) - the view model auto-dismisses in that case and
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

    /// Inboxes of the conversation's DM-able agents, one per verified agent
    /// member, when the agent-DM prototype should offer DM pages: not already
    /// inside a DM, non-production only (matches ContactDetailView's gate).
    /// Kept in member join order (`_members` is ordered createdAt.asc), so a
    /// newly-added agent appends a page after the existing ones rather than
    /// reordering them and relocating a DM the user already opened.
    private var agentDmPageInboxIds: [String] {
        guard !ConfigManager.shared.currentEnvironment.isProduction,
              !viewModel.conversation.isAgentDm else {
            return []
        }
        return viewModel.conversation.members
            .filter { $0.isVerifiedAgent }
            .map { $0.profile.inboxId }
    }

    private var conversationPager: some View {
        ConversationPager(
            selectedPage: $pagerSelectedPage,
            pages: pagerPages,
            showsPageDots: !isKeyboardVisible && !isNewComposerActive,
            dotsHidden: contextMenuState.isPresented,
            scrollingDisabled: contextMenuState.isPresented,
            usesStationaryPages: isDesktopActive,
            messagesPage: { messagesView },
            agentDmPage: { agentInboxId in
                let isActive: Bool = pagerSelectedPage == .agentDm(agentInboxId: agentInboxId)
                AgentDmPageView(
                    viewModel: viewModel,
                    agentInboxId: agentInboxId,
                    extraBottomInset: pagerDotsInset,
                    isReadOnly: effectiveReadOnly,
                    isActivePage: isActive,
                    keyboardVisible: isKeyboardVisible
                )
            },
            agentPage: {
                let isActive: Bool = pagerSelectedPage == .agent
                AgentPageView(
                    viewModel: viewModel,
                    agentInboxIds: agentDmPageInboxIds,
                    selectedAgentInboxId: $selectedAgentInboxId,
                    extraBottomInset: pagerDotsInset,
                    isReadOnly: effectiveReadOnly,
                    isActivePage: isActive,
                    keyboardVisible: isKeyboardVisible,
                    drivesWindowColorScheme: !isDesktopActive
                )
            },
            thingsPage: { thingsPage }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            switcherBar
        }
    }

    /// The Group/Agent switcher pinned in the slot the pager dots occupy,
    /// mounted only when the new-composer layout is active. Pinned outside
    /// the pager so it stays fixed while pages swipe horizontally.
    @ViewBuilder
    private var switcherBar: some View {
        if isNewComposerActive {
            GroupAgentSwitcher(
                selectedPage: $pagerSelectedPage,
                showsAgentPill: agentTabAvailable,
                usesHomeStyle: isDesktopActive
            )
            .padding(.bottom, DesignConstants.Spacing.step2x)
            .onGeometryChange(
                for: CGFloat.self,
                of: { $0.size.height },
                action: { height in
                    guard isDesktopActive, height != desktopSwitcherHeight else { return }
                    desktopSwitcherHeight = height
                }
            )
        }
    }

    @ViewBuilder
    private var layoutRoot: some View {
        Group {
            if isDesktopActive {
                desktopLayout
            } else {
                conversationPager
            }
        }
        .overlay {
            if viewModel.isUpgradingDmToGroup {
                upgradeInProgressOverlay
            }
        }
    }

    /// Shown while a human DM is being forked into a new group. The screen
    /// swaps to the new group once creation completes (see
    /// `ConversationViewModel.upgradeDmToGroup`).
    private var upgradeInProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            ProgressView("Creating group…")
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
    }

    var body: some View {
        layoutRoot
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            handleKeyboardWillShow(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                keyboardHeight = 0
            }
        }
        .onChange(of: focusState) { oldFocus, newFocus in
            handleComposerFocusChanged(from: oldFocus, to: newFocus)
        }
        .onChange(of: pagerSelectedPage) { _, newPage in
            let keyboardWasUp: Bool = isKeyboardVisible
            if newPage != .things {
                focusCoordinator.dismissThingsSearchIfNeeded()
            }
            if newPage == .messages {
                // Returning to the group: transfer the keyboard back onto the
                // group composer when the user paged in mid-edit.
                if keyboardWasUp {
                    focusCoordinator.moveFocus(to: .message)
                }
            } else {
                // Leaving the group for a peer page: release the group composer.
                // The DM page re-grabs focus onto its own composer (transferring
                // the keyboard); the Things page has no composer, so it drops.
                focusCoordinator.dismissMessageComposerIfNeeded()
                // A right-swipe can both start a reply and page away; cancel the
                // in-flight reply swipe so the page change doesn't fire a reply.
                contextMenuState.cancelInFlightSwipe()
            }
        }
        .onChange(of: viewModel.messageText) { _, _ in
            viewModel.checkForInviteURL()
            viewModel.checkForAgentShareURL()
            viewModel.checkForPastedLink()
        }
        .modifier(agentPagesObservers)
        .animation(.easeOut, value: viewModel.explodeState)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onAppear {
            ensureNavigator()
            navState.markScreenAppeared()
            viewModel.onConversationAppeared()
            seedInitialPageIfNeeded()
            seedInitialDrawerDetentIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAgentDmPageRequested)) { note in
            handleSelectAgentDmPageRequest(note)
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
            // ProfileSetupSheet owns the full save; no dismiss handler -
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

// The desktop-mode layout and the Group/Agent tab support, in an extension
// so the main struct stays within the type-body-length budget.
private extension ConversationView {
    var pagerDotsInset: CGFloat {
        if isDesktopActive {
            return desktopSwitcherHeight > 0 ? desktopSwitcherHeight : Constant.switcherBottomInset
        }
        if isNewComposerActive {
            // The switcher stays mounted with the keyboard up, so the
            // transcript keeps clearing it in both states.
            return Constant.switcherBottomInset
        }
        return isKeyboardVisible ? 0.0 : 24.0
    }

    /// Whether the redesigned composer layout (Group/Agent switcher in place
    /// of the pager dots) is active. Desktop mode implies it.
    var isNewComposerActive: Bool {
        FeatureFlags.shared.isNewComposerActive
    }

    /// Focusing first opens the collapsed card; keyboard presentation then
    /// promotes it to full height below.
    func handleComposerFocusChanged(
        from oldFocus: MessagesViewInputFocus?,
        to newFocus: MessagesViewInputFocus?
    ) {
        guard isDesktopActive,
              oldFocus != .message,
              newFocus == .message,
              drawerDetent == .collapsed else {
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            drawerDetent = .partial
        }
    }

    /// Opens the desktop drawer to the medium (partial) detent when the
    /// conversation has unread messages, so they are visible on arrival, and
    /// leaves it collapsed otherwise. Seeded once, only in desktop mode.
    func seedInitialDrawerDetentIfNeeded() {
        guard isDesktopActive, !didSeedDrawerDetent else { return }
        didSeedDrawerDetent = true
        drawerDetent = viewModel.conversation.isUnread ? .partial : .collapsed
    }

    /// Drops the composer keyboard: clears the coordinator's focus and resigns
    /// the first responder directly, since the agent-DM pages own a local focus
    /// state the coordinator can't reach.
    func dismissComposerKeyboard() {
        focusCoordinator.moveFocus(to: nil)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// A visible keyboard always owns the full desktop drawer. This also
    /// handles agent-page composers, whose focus state is local to that page.
    /// The docked keyboard height is captured so the desktop scroll surface can
    /// reserve room for it below the raised compose card.
    func handleKeyboardWillShow(_ notification: Notification) {
        isKeyboardVisible = true
        let frameHeight: CGFloat? = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height
        let shouldPromoteDrawer: Bool = isDesktopActive && drawerDetent != .full
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if let frameHeight {
                keyboardHeight = frameHeight
            }
            if shouldPromoteDrawer {
                drawerDetent = .full
            }
        }
    }

    /// Whether the desktop layout (webview desktop + chat drawer) is active:
    /// the host opted in, the flag is on, and this is a real group (agent DMs
    /// are protocol-level groups, so `kind` alone can't exclude them).
    var isDesktopActive: Bool {
        let conversation = viewModel.conversation
        // Human DMs keep the standard conversation UX (no desktop surface, no
        // drawer); only real groups get the desktop layout.
        let isGroup: Bool = conversation.kind == .group && !conversation.isAgentDm && !conversation.isHumanDm
        return allowsDesktopMode && isGroup && FeatureFlags.shared.isDesktopModeEnabled
    }

    /// Whether the single Agent tab (the `.agent` page + switcher pill) is
    /// offered: mirrors the agent-DM prototype's non-production gate and
    /// never inside an agent DM itself. Also hidden in a desktop-mode human
    /// DM: a DM has no agents, so the tab could only show its empty state,
    /// whose CTA can't operate in place (every agent path out of a DM forks
    /// into a new group). The agent-add path is the picker's template rows.
    var agentTabAvailable: Bool {
        !ConfigManager.shared.currentEnvironment.isProduction
            && !viewModel.conversation.isAgentDm
            && !viewModel.upgradesOnAdd
    }

    var pagerPages: [ConversationPagerPage] {
        if isNewComposerActive {
            // The switcher path collapses every agent DM into the single
            // `.agent` page; the Things page is folded into the desktop
            // surface when that layout is active.
            var pages: [ConversationPagerPage] = [.messages]
            if agentTabAvailable {
                pages.append(.agent)
            }
            if !isDesktopActive {
                pages.append(.things)
            }
            return pages
        }
        var pages: [ConversationPagerPage] = [.messages]
        for agentInboxId in agentDmPageInboxIds {
            pages.append(.agentDm(agentInboxId: agentInboxId))
        }
        if !isDesktopActive {
            pages.append(.things)
        }
        return pages
    }

    /// The desktop-mode layout: the sectioned desktop surface always fills
    /// the screen, in both tabs, with the chat pager (composer included)
    /// inside the collapsible bottom drawer. The switcher only changes what
    /// the drawer shows. The drawer rests collapsed as a compose card with
    /// the chat concealed; on the Group tab it shares the desktop's light
    /// surface so no container reads around the composer, while the Agent
    /// tab darkens the drawer (chat and composer) into the visible floating
    /// card. The desktop behind keeps the ambient scheme either way.
    var desktopLayout: some View {
        let drawerColorScheme: ColorScheme = pagerSelectedPage == .agent ? .dark : systemColorScheme
        return ZStack {
            DesktopLayoutView(
                inviteConfiguration: desktopInviteConfiguration,
                drawerHeight: drawerHeight
            )
            .ignoresSafeArea(edges: .bottom)
            ConversationDrawer(
                detent: $drawerDetent,
                extraCollapsedHeight: nagBarExtraHeight,
                keyboardHeight: keyboardHeight,
                onDismissKeyboard: dismissComposerKeyboard,
                content: { expansion in
                    conversationPager
                        .environment(\.desktopTranscriptOpacity, Double(expansion))
                }
            )
            .environment(\.colorScheme, drawerColorScheme)
            .onPreferenceChange(ConversationDrawerHeightPreferenceKey.self) { height in
                drawerHeight = height
            }
        }
    }

    /// Extra collapsed-drawer height reserving room for the nag bar
    /// (capability toast / onboarding) above the composer; zero when the bar
    /// is empty. The spacing term matches the bottom-bar VStack's spacing.
    var nagBarExtraHeight: CGFloat {
        guard nagBarHeight > 0 else { return 0 }
        return nagBarHeight + DesignConstants.Spacing.step3x
    }

    /// The nag-bar slot below the composer. Capability requests no longer
    /// auto-present a card here: the transcript's connect pill is the single
    /// entry point and opens the approval sheet. The slot keeps the
    /// post-approval toast and the onboarding view. Its height is measured so
    /// the desktop drawer's collapsed detent can reserve room for it.
    @ViewBuilder
    func conversationNagBar(onboardingCoordinator: ConversationOnboardingCoordinator) -> some View {
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
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: handleNagBarHeightChanged)
    }

    func handleNagBarHeightChanged(_ height: CGFloat) {
        nagBarHeight = height
    }

    /// Clears the agent-page selection when the selected agent leaves the
    /// conversation, letting `AgentPageView` fall back to the first agent.
    func handleAgentDmInboxIdsChanged(_ inboxIds: [String]) {
        guard let selected = selectedAgentInboxId, !inboxIds.contains(selected) else { return }
        selectedAgentInboxId = nil
    }

    /// Returns the pager to the group when the selected page vanishes from
    /// the page set (e.g. desktop mode flipping on while the user is on
    /// Things). Scoped to the new-composer path so legacy behavior is
    /// unchanged.
    func handlePagerPagesChanged(_ pages: [ConversationPagerPage]) {
        guard isNewComposerActive, !pages.contains(pagerSelectedPage) else { return }
        pagerSelectedPage = .messages
    }
}

// File scope because static stored properties aren't supported inside the
// generic conversation view type.
private enum Constant {
    /// Extra transcript inset clearing the Group/Agent switcher below the
    /// composer; taller than the dots' 24pt because the switcher carries
    /// labeled pills. Tuned in the simulator.
    static let switcherBottomInset: CGFloat = 64.0
}

// The sheet/navigation onChange handlers: each maps a viewModel
// presentation flag flipping true to a navigator present call.
private extension ConversationView {
    func handleConversationSettingsChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(conversationInfo: ConversationInfoNavigatorArgs(conversationId: conversationIdForMetrics))
    }

    func handleProfileSettingsChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(myInfo: MyInfoNavigatorArgs())
    }

    func handleShareViewChanged(from oldValue: Bool, to newValue: Bool) {
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

    func handleConversationForkedChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(conversationForkedInfo: ConversationForkedInfoNavigatorArgs(conversationId: conversationIdForMetrics))
    }

    func handleExplodedInviteInfoChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(explodedInviteInfo: ExplodedInviteInfoNavigatorArgs())
    }

    func handleAgentsIntroChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(assistantConfirmation: AssistantConfirmationNavigatorArgs(conversationId: conversationIdForMetrics))
    }

    func handlePaywallChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(paywall: PaywallNavigatorArgs(source: .lowBalanceBanner))
    }

    func handleAgentsInfoChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(agentInfo: AgentInfoNavigatorArgs())
    }

    func handleLockedInfoChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(lockedConvoInfo: LockedConvoInfoNavigatorArgs(conversationId: conversationIdForMetrics))
    }

    func handleFullInfoChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(fullConvoInfo: FullConvoInfoNavigatorArgs())
    }

    func handlePhotosInfoChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(photosInfo: PhotosInfoNavigatorArgs())
    }

    func handleAgentBuilderChanged(from wasPresenting: Bool, to isPresenting: Bool) {
        guard !wasPresenting, isPresenting else { return }
        navigator?.present(agentBuilder: AgentBuilderNavigatorArgs(conversationId: conversationIdForMetrics, entryMode: .sheet))
    }

    func handleNewConvoInviteChanged(from wasPresenting: Bool, to isPresenting: Bool) {
        guard !wasPresenting, isPresenting else { return }
        navigator?.present(newConversation: NewConversationNavigatorArgs(mode: .joinInvite))
    }

    /// The agent-share placeholder card reports as a member-profile present
    /// with the placeholder's sentinel inbox id (`agent-share:<templateId>`),
    /// keeping "a profile card opened from this conversation" consistent in
    /// analytics with the member-avatar path while staying distinguishable.
    func handleAgentShareContactChanged(from oldContact: Contact?, to newContact: Contact?) {
        guard oldContact == nil, let newContact else { return }
        navigator?.present(
            memberProfile: MemberProfileNavigatorArgs(
                conversationId: conversationIdForMetrics,
                memberId: newContact.inboxId
            )
        )
    }

    func handleMemberProfileChanged(from oldMember: ConversationMember?, to newMember: ConversationMember?) {
        guard oldMember == nil, let newMember else { return }
        navigator?.present(
            memberProfile: MemberProfileNavigatorArgs(
                conversationId: conversationIdForMetrics,
                memberId: newMember.profile.inboxId
            )
        )
    }

    func handleReactionsChanged(from oldMessage: AnyMessage?, to newMessage: AnyMessage?) {
        guard oldMessage == nil, let newMessage else { return }
        navigator?.present(
            reactions: ReactionsNavigatorArgs(
                conversationId: conversationIdForMetrics,
                messageId: newMessage.id
            )
        )
    }

    func handleThinkingDetailChanged(from oldValue: ThinkingSessionDescriptor?, to newValue: ThinkingSessionDescriptor?) {
        guard oldValue == nil, let newValue else { return }
        navigator?.present(
            thinkingDetail: ThinkingDetailNavigatorArgs(
                conversationId: conversationIdForMetrics,
                senderInboxId: newValue.sender.profile.inboxId,
                messageId: newValue.targetMessageId
            )
        )
    }

    func handleAddFromContactsChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        navigator?.present(
            addMembers: AddMembersNavigatorArgs(
                conversationId: conversationIdForMetrics,
                conversationTitle: viewModel.conversation.name
            )
        )
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
    var onStartAgentDm: ((String) -> Void)?
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
                onRemove: onRemove,
                onStartAgentDm: onStartAgentDm
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
        // Agent DMs are private 2-member conversations; never offer invites.
        guard !conversation.isAgentDm else { return false }
        return conversation.creator.isCurrentUser && !conversation.isLocked && !conversation.isFull && !conversation.leftHostedInviteSession
    }

    /// Non-nil only when the desktop layout should carry the scan/invite
    /// section; eligibility mirrors the inline card (`showsTopOfConvoInvite`)
    /// and the inputs mirror the transcript's index-0 invite cell.
    private var desktopInviteConfiguration: DesktopInviteSectionConfiguration? {
        guard showsTopOfConvoInvite else { return nil }
        return DesktopInviteSectionConfiguration(
            conversation: viewModel.conversation,
            invite: viewModel.invite,
            mode: inviteScanMode,
            initialSegment: embeddedInviteInitialSegment,
            onScannedCode: inviteScanScannedHandler,
            onShareCompleted: onInviteShareCompletedHandler
        )
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

    private var agentPagesObservers: AgentPagesObserversModifier {
        AgentPagesObserversModifier(
            agentDmInboxIds: agentDmPageInboxIds,
            pagerPages: pagerPages,
            onAgentDmInboxIdsChanged: handleAgentDmInboxIdsChanged(_:),
            onPagerPagesChanged: handlePagerPagesChanged(_:)
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

private extension ConversationView {
    /// What the composer needs to draw the bubble: the level, and the change.
    /// `nil` in a conversation with no agent — a control for agents has no
    /// business in a room without one. The bubble presents the levels as a
    /// system menu itself, so no card hosting lives here.
    var participationContext: AgentParticipationContext? {
        guard let participation else { return nil }
        return AgentParticipationContext(
            level: participation.level,
            isLoading: !participation.hasLoaded
        ) { level in
            Task { await participation.set(level) }
        }
    }

    /// Keys the participation `.task` on the conversation AND on whether it has
    /// an agent, so an agent that joins an already-open conversation re-runs
    /// `prepareParticipation` and surfaces the control — keying on the
    /// conversation id alone would miss that transition.
    var participationTaskKey: String {
        let hasAgent = viewModel.conversation.members.contains(where: \.isAgent)
        return "\(viewModel.conversation.id)-\(hasAgent)"
    }

    /// Builds the store for this conversation, seeded with the mode the synced
    /// conversation already carries. Skipped where the control would be
    /// meaningless, so a conversation without agents never draws it.
    func prepareParticipation() async {
        guard FeatureFlags.shared.isListenParticipationEnabled,
              viewModel.conversation.members.contains(where: \.isAgent) else {
            participation = nil
            return
        }
        let mode = viewModel.conversation.participationMode
        let store = AgentParticipationStore(
            conversationId: viewModel.conversation.id,
            variantId: FeatureFlags.shared.selectedAgentVariant?.slug,
            service: ConversationAppDataParticipationService(
                metadataWriter: viewModel.conversationMetadataWriter,
                mode: mode
            )
        )
        store.apply(syncedLevel: AgentParticipationLevel(mode: mode))
        participation = store
    }
}
