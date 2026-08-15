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
    /// Routes a code decoded by the embedded Scan segment to the new-convo join
    /// path. Nil keeps the embedded viewfinder decode-only.
    var onScannedInviteCode: ((String) -> Void)?
    /// Fires when the embedded invite's "Share invite link" completes, so the
    /// backing new-convo flow can mark its invite as shared and skip the
    /// empty-conversation teardown that would otherwise break the shared link.
    var onInviteShared: (() -> Void)?
    /// Fires as the Home tab's browsing chain fills and empties. While a page
    /// is pushed this view puts its own back button in the leading slot, so a
    /// host that renders one too (the new-convo sheet's close) hides its own
    /// and the bar keeps a single leading button.
    var onHomeBrowsingChanged: ((Bool) -> Void)?
    @ViewBuilder let bottomBarContent: () -> MessagesBottomBar

    @State private var showingLockedInfo: Bool = false
    @State private var showingFullInfo: Bool = false
    @State private var showingAgentsInfo: Bool = false
    /// Agent participation for this conversation, behind the Listen debug flag.
    /// It lives here rather than in the composer because the level belongs to
    /// the conversation; the composer only draws the control.
    @State private var participation: AgentParticipationStore?
    /// The conversation sheet's selected tab, the single source of truth for
    /// both the backing view behind the sheet and the bar the sheet hosts.
    @State private var selectedTab: ConversationTab = .group
    /// Tabs the user has visited. The agent DM mounts on first visit and stays
    /// mounted (hidden, not torn down) so tab switches never reload it.
    @State private var visitedTabs: Set<ConversationTab> = [.group]
    /// Guards the one-time seed of `selectedTab` from `initialAgentDmInboxId`.
    @State private var didSeedInitialTab: Bool = false
    /// How much of the selected transcript the sheet is showing. Seeded per
    /// conversation by `seedInitialTabIfNeeded`.
    @State private var sheetDetent: ConversationSheetDetent = .collapsed
    /// The sheet's measured chrome height (bar plus tab bar), reported back by
    /// the sheet, and what the Home insets its content by so nothing important
    /// hides behind the resting sheet. Deliberately not the sheet's live
    /// height: the Home must not reflow every time the sheet is dragged.
    ///
    /// Excludes the bottom safe area, because the transcripts take this value
    /// as a content inset and their collection views add their own safe area on
    /// top of it (`contentInsetAdjustmentBehavior == .always`). The detent
    /// needs the safe area included, so it adds it back - see
    /// `sheetOccupiedChromeHeight`.
    @State private var sheetChromeHeight: CGFloat = ConversationSheetMetrics.estimatedCollapsedHeight
    /// Height of the selected transcript's last message, which is what the
    /// `compact` detent sizes itself to.
    @State private var lastMessageHeight: CGFloat = 0
    /// Window safe-area insets, used to convert the sheet's physical-edge
    /// clearance into the safe-area-relative inset the transcripts take.
    @Environment(\.safeAreaInsets) private var windowSafeAreaInsets: EdgeInsets
    /// The scheme the conversation is presented in, sampled while the Agent
    /// tab is not forcing its own. See `preferredScheme`.
    @Environment(\.colorScheme) private var presentedColorScheme: ColorScheme
    @State private var ambientColorScheme: ColorScheme?
    /// Binds the Agent tab to the agent's real DM conversation; shared by the
    /// backing transcript and the sheet's agent composer.
    @State private var agentDmSession: AgentDmSession?
    /// Tracks keyboard visibility so tab switches can transfer composer
    /// focus between the group and agent composers.
    @State private var isKeyboardVisible: Bool = false
    /// Lifted out of `MessagesView` so this view can hide the conversation
    /// sheet while the long-press context menu is presented.
    @State private var contextMenuState: MessageContextMenuState = .init()
    /// The agent DM transcript's own context-menu state; the DM stays mounted
    /// alongside the group transcript, so they cannot share one.
    @State private var agentContextMenuState: MessageContextMenuState = .init()
    /// Focus for the sheet's agent composer, deliberately separate from the
    /// group composer's `focusState`: both surfaces stay mounted, so a shared
    /// value would fight between their text fields.
    @FocusState private var agentFocusState: MessagesViewInputFocus?
    @State private var agentFocusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: .compact)
    /// Scroll-to-bottom triggers bridged out of each transcript for the
    /// sheet-hosted composers to fire on send.
    @State private var groupScrollToBottom: (() -> Void)?
    @State private var agentScrollToBottom: (() -> Void)?
    /// The home browsing chain, layered over the home and below the
    /// floating sheet so browsing never leaves the conversation screen.
    /// While non-empty, the top bar swaps the system back button for one
    /// that pops pages, and hides the add-members item.
    @State private var homeBrowserEntries: [HomeBrowserEntry] = []
    @State private var showingDebugInjector: Bool = false
    /// Consent surface for agent ability-use asks, managed by
    /// `prepareEscalationIfNeeded` keyed on `escalationTaskKey` (nil while
    /// the abilities flag is off or the conversation has no agent; rebuilt
    /// when the shown conversation changes).
    @State private var escalationViewModel: ConversationEscalationViewModel?
    @State private var presentingAddFromContactsPicker: Bool = false
    /// Drives the system share sheet behind the top bar's invite-link button.
    @State private var presentingInviteShareSheet: Bool = false
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
        MessagesView(
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
            onboardingCoordinator: viewModel.onboardingCoordinator,
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
            // "Invite friends" hands the link straight to the system share
            // sheet - the same thing the top bar's share button does. A full
            // conversation can't mint invites, so it explains itself instead.
            onConvoCode: {
                if viewModel.isFull {
                    showingFullInfo = true
                } else {
                    presentingInviteShareSheet = true
                }
            },
            onInviteAgent: {},
            onRetryTranscript: { item in
                viewModel.retryTranscript(for: item)
            },
            profileSheetForMember: profileSheetForMember,
            memberContactOverride: contactOverride,
            isAgentJoinPending: viewModel.isAgentJoinPending,
            headerMode: effectiveHeaderMode,
            agentBuilderSummary: viewModel.agentBuilderSummary,
            onVoiceMemoTap: { viewModel.onVoiceMemoTapped() },
            voiceMemoRecorder: viewModel.voiceMemoRecorder,
            onSendVoiceMemo: { viewModel.sendVoiceMemo() },
            onDebugAttachmentTap: debugAttachmentTapHandler,
            // The list ignores the safe area, so its content inset comes from
            // this number alone - the safe-area inset the sheet's chrome
            // contributes is opted out of and adds nothing. The clearance is
            // the chrome's height plus the bottom safe area, because the
            // chrome is positioned above the home indicator while this frame
            // runs to the screen edge. `sheetChromeHeight` carries both.
            extraBottomInset: sheetChromeHeight,
            // The composer lives in the conversation sheet now (see
            // `sheetBarContent`), so the transcript renders no bar of its own.
            hostsBottomBar: false,
            onScrollToBottomAvailable: { scrollFn in
                // Fires from inside the representable's make pass; defer the
                // state write out of the view-update transaction or SwiftUI
                // drops it.
                DispatchQueue.main.async {
                    groupScrollToBottom = scrollFn
                }
            },
            bottomBarContent: { EmptyView() }
        )
        // Only where there is an agent to govern, and only while the Listen
        // flag is on. Absent, the composer draws no bubble at all.
        .environment(\.agentParticipation, participationContext)
        .task(id: participationTaskKey) { await prepareParticipation() }
        .task(id: escalationTaskKey) { prepareEscalationIfNeeded() }
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

    /// True while the Agent tab is selected. The DM is a fixed 2-member
    /// conversation, so the invite/add-member affordance is hidden there.
    private var isAgentDmPageActive: Bool {
        selectedTab == .agent
    }

    /// Chooses the transcript this conversation opens on and how much of it is
    /// showing, once. See `ConversationTab.initial(available:agentDmRequested:)`
    /// and `ConversationSheetDetent.initial(hasUnread:agentDmRequested:)`.
    private func seedInitialTabIfNeeded() {
        guard !didSeedInitialTab else { return }
        didSeedInitialTab = true
        let agentDmRequested: Bool = initialAgentDmInboxId != nil
            && initialAgentDmInboxId == primaryAgentInboxId
        sheetDetent = ConversationSheetDetent.initial(
            hasUnread: hasUnreadToRead,
            agentDmRequested: agentDmRequested
        )
        let tab: ConversationTab = ConversationTab.initial(
            available: availableTabs,
            agentDmRequested: agentDmRequested
        )
        guard tab != selectedTab else { return }
        selectTab(tab)
    }

    /// Whether anything in this conversation is waiting to be read, across the
    /// group and the agent DM. The DM's own view model may not have bound yet
    /// when the tab is seeded, so a list row that opened us *because* the DM
    /// was unread counts on its own.
    private var hasUnreadToRead: Bool {
        if viewModel.conversation.isUnread { return true }
        if initialAgentDmInboxId != nil { return true }
        return agentDmSession?.dmViewModel?.conversation.isUnread == true
    }

    /// Switches to the Agent tab when a DM notification is tapped while this
    /// conversation is already on screen (a fresh open seeds the tab from
    /// `initialAgentDmInboxId`, but re-selecting the same conversation is a
    /// no-op, so an already-open view has to be told directly). Ignores
    /// requests for a different conversation.
    private func handleSelectAgentDmPageRequest(_ note: Notification) {
        guard let conversationId = note.userInfo?["conversationId"] as? String,
              conversationId == viewModel.conversation.id else {
            return
        }
        selectTab(.agent)
    }

    /// Programmatic tab selection: keeps `visitedTabs` in sync (the
    /// `onChange(of: selectedTab)` hook does the same for user taps).
    private func selectTab(_ tab: ConversationTab) {
        visitedTabs.insert(tab)
        selectedTab = tab
    }

    /// The agent the Agent tab binds to: the conversation's first verified
    /// agent member, in join order (`_members` is ordered createdAt.asc), so
    /// a newly-added agent never displaces the DM the user already opened.
    /// Nil while the conversation has no verified agent (the tab still
    /// renders, with its empty state and a disabled composer) or when this
    /// conversation is itself an agent DM.
    private var primaryAgentInboxId: String? {
        guard !viewModel.conversation.isAgentDm else { return nil }
        return viewModel.conversation.members
            .first { $0.isVerifiedAgent }?
            .profile.inboxId
    }

    /// Identity of the agent binding: which agent, and which view model it is
    /// resolved against. The host can replace the latter without the former
    /// changing.
    private struct AgentBindingKey: Equatable {
        let conversationViewModel: ObjectIdentifier
        let agentInboxId: String?
    }

    private var agentBindingKey: AgentBindingKey {
        AgentBindingKey(
            conversationViewModel: ObjectIdentifier(viewModel),
            agentInboxId: primaryAgentInboxId
        )
    }

    /// Every conversation offers both transcripts.
    private var availableTabs: [ConversationTab] {
        ConversationTab.allCases
    }

    /// Per-tab unread indicators, from the surfaces' own conversations. The
    /// active tab never badges - the user is looking at it, and leaving a
    /// tab marks its conversation read (see the tab-change handler).
    private var badgedTabs: Set<ConversationTab> {
        var badged: Set<ConversationTab> = []
        if selectedTab != .group, viewModel.conversation.isUnread {
            badged.insert(.group)
        }
        if selectedTab != .agent,
           agentDmSession?.dmViewModel?.conversation.isUnread == true {
            badged.insert(.agent)
        }
        return badged
    }

    /// The Agent tab is a dark surface, and its composer's materials resolve
    /// against the UIKit trait collection rather than SwiftUI's environment,
    /// so the scheme has to be forced rather than set in the environment.
    ///
    /// Applied to the sheet alone. Driving the whole screen dark would take
    /// the Home behind it along, which belongs to the conversation, not to the
    /// tab the sheet happens to be showing.
    ///
    /// Leaving the group at "no preference" (nil) looks equivalent but isn't:
    /// the forced trait sticks, and the group chat comes back dark. Handing
    /// back the scheme the conversation was presented in restores it
    /// explicitly.
    private var preferredScheme: ColorScheme? {
        selectedTab == .agent ? .dark : ambientColorScheme
    }

    /// Samples the presented scheme, ignoring the value the Agent tab forces -
    /// sampling that would feed the forced scheme back in as the ambient one
    /// and leave every tab dark.
    private func captureAmbientScheme(_ scheme: ColorScheme) {
        guard selectedTab != .agent else { return }
        ambientColorScheme = scheme
    }

    /// The full height the chrome occupies from the physical screen edge: its
    /// own measured height plus the home-indicator safe area it rests above.
    /// This is what the `collapsed` detent resolves to, since a detent is a
    /// presentation height measured from that edge.
    private var sheetOccupiedChromeHeight: CGFloat {
        sheetChromeHeight + windowSafeAreaInsets.bottom
    }

    /// The layout plus the tab/focus/session observers, split from `body`
    /// to keep each expression inside the type-check budget.
    private var conversationCore: some View {
        conversationLayout
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            handleSelectedTabChange(from: oldTab, to: newTab)
        }
        // The agent composer's focus plumbing, mirroring what
        // ConversationPresenter wires for the group pair: coordinator ->
        // FocusState (including same-value refocus re-assertion) and
        // FocusState -> coordinator.
        .onChange(of: agentFocusCoordinator.currentFocus) { _, newFocus in
            agentFocusState = newFocus
        }
        .onChange(of: agentFocusCoordinator.refocusNonce) { _, _ in
            reassertAgentFocus()
        }
        .onChange(of: agentFocusState) { _, newFocus in
            agentFocusCoordinator.syncFocusState(newFocus)
        }
        // Losing the Space URL drops any pages browsed from it, but the tab
        // stays: without a URL the Home shows its preparing state rather than
        // moving the user somewhere they did not ask to go.
        .onChange(of: viewModel.conversation.spaceURL) { _, newURL in
            if newURL == nil {
                homeBrowserEntries.removeAll()
            }
        }
        // Keeps the Agent tab bound to the conversation's current agent, and
        // keeps retrying the DM bind until the agent-created DM syncs in.
        // Keyed on the view model too: the new-convo flow swaps a placeholder
        // for the real conversation, and the session must follow it even when
        // the agent itself has not changed.
        .task(id: agentBindingKey) {
            let session = agentDmSession ?? AgentDmSession(originViewModel: viewModel)
            if agentDmSession == nil {
                agentDmSession = session
            }
            session.updateOrigin(viewModel)
            session.setAgent(inboxId: primaryAgentInboxId)
            await session.rebindWhenDmAppears()
        }
    }

    var body: some View {
        conversationCore
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
            captureAmbientScheme(presentedColorScheme)
            // Seed before the viewed check: a DM-notification open lands
            // straight on the agent page, and the group must not count as
            // viewed (its unread state and read receipts stay untouched
            // until its tab actually shows). Same when returning from a
            // push while on a non-Group tab.
            seedInitialTabIfNeeded()
            if selectedTab == .group {
                viewModel.onConversationAppeared()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAgentDmPageRequested)) { note in
            handleSelectAgentDmPageRequest(note)
        }
        .onDisappear {
            viewModel.onConversationDisappeared()
            navigator?.closed(context: navState.closeContext())
            escalationViewModel?.stopObserving()
        }
        // Keep the edge-swipe back gesture, drop the content-area one while
        // this screen is up (see ContentPopGestureDisabler).
        .background {
            ContentPopGestureDisabler()
                .frame(width: 0, height: 0)
        }
        // While browser pages are showing, the pop-a-page back button in
        // `topBarTrailing` stands in for the system one.
        .navigationBarBackButtonHidden(isBrowsingHome)
        .modifier(HomeBrowsingReporter(isBrowsing: isBrowsingHome, onChanged: onHomeBrowsingChanged))
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
        .onChange(of: presentedColorScheme) { _, scheme in
            captureAmbientScheme(scheme)
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
        .shareSheet(
            isPresented: $presentingInviteShareSheet,
            items: inviteShareItems,
            onCompletion: handleInviteShareCompletion
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

// MARK: - Tab switching

private extension ConversationView {
    /// Focus transfers ride the coordinators - each composer has its own
    /// (both surfaces stay mounted, so raw FocusState writes would fight) -
    /// releasing the outgoing composer and, when the user switched mid-edit,
    /// claiming the incoming one so the keyboard hands over instead of
    /// dropping.
    private func handleSelectedTabChange(from oldTab: ConversationTab, to newTab: ConversationTab) {
        visitedTabs.insert(newTab)
        let keyboardWasUp: Bool = isKeyboardVisible
        switch newTab {
        case .group:
            if keyboardWasUp {
                // Claim the incoming composer directly - the outgoing field
                // resigns implicitly and its sync wiring clears its
                // coordinator. Explicitly dismissing first leaves a beat
                // with no first responder and the keyboard visibly dips.
                focusCoordinator.moveFocus(to: .message)
            } else {
                agentFocusCoordinator.dismissMessageComposerIfNeeded()
            }
        case .agent:
            if keyboardWasUp {
                agentFocusCoordinator.moveFocus(to: .message)
            } else {
                focusCoordinator.dismissMessageComposerIfNeeded()
            }
        }
        // A right-swipe can both start a reply and switch away; cancel the
        // in-flight reply swipe so the tab change doesn't fire one.
        if oldTab == .group {
            contextMenuState.cancelInFlightSwipe()
        }
        // The group is "being viewed" only while its tab is selected. Off
        // the tab, read receipts must stop (the user isn't reading the
        // transcript) and the group has to leave the active-conversation
        // gate so incoming messages mark it unread and badge its tab.
        if oldTab == .group, newTab != .group {
            handleGroupTabLeft()
        } else if oldTab != .group, newTab == .group {
            viewModel.onConversationAppeared()
            updateActiveGroupLane(isActive: true)
        }
    }

    /// Leaving the Group tab. When the group was actually on screen,
    /// anything that arrived while the user watched is read, so it doesn't
    /// badge the tab they left - and that write has to land before the
    /// group leaves the active-conversation gate, or a message arriving
    /// between the two would badge and then be wiped by the stale write.
    /// When the group was never viewed (opening seeded straight onto the
    /// agent page), its unread state is left untouched.
    private func handleGroupTabLeft() {
        guard viewModel.isViewingConversation else {
            updateActiveGroupLane(isActive: false)
            return
        }
        viewModel.onConversationDisappeared()
        let conversationId: String = viewModel.conversation.id
        let messagingService = viewModel.messagingService
        Task {
            do {
                try await messagingService
                    .conversationLocalStateWriter()
                    .setUnread(false, for: conversationId)
            } catch {
                Log.warning("Failed marking group as read: \(error.localizedDescription)")
            }
            // The user may have returned to the group while the write was
            // in flight; deactivating now would unregister a viewed tab.
            if selectedTab != .group {
                updateActiveGroupLane(isActive: false)
            }
        }
    }

    /// Registers (or clears) the group as the on-screen conversation. The
    /// conversations list posts the group id when this screen opens; leaving
    /// the Group tab hands the slot back so the stream's unread gate and
    /// push suppression treat the group like any background conversation.
    /// (The agent page does the same for its DM lane.)
    private func updateActiveGroupLane(isActive: Bool) {
        let conversationId: String = viewModel.conversation.id
        NotificationCenter.default.post(
            name: .activeConversationChanged,
            object: nil,
            userInfo: isActive ? ["conversationId": conversationId] : [:]
        )
    }

    /// Re-applies the agent composer's `@FocusState` for a same-value
    /// `moveFocus` request (see `FocusCoordinator.refocusNonce`), bouncing
    /// through nil when needed so SwiftUI re-acquires the first responder.
    private func reassertAgentFocus() {
        let target = agentFocusCoordinator.currentFocus
        guard agentFocusState == target else {
            agentFocusState = target
            return
        }
        agentFocusState = nil
        DispatchQueue.main.async {
            agentFocusState = target
        }
    }

    private func pushHomeBrowserPage(for url: URL) {
        withAnimation(.easeInOut(duration: 0.25)) {
            homeBrowserEntries.append(HomeBrowserEntry(url: url))
        }
    }

    private func popHomeBrowserPage() {
        withAnimation(.easeInOut(duration: 0.25)) {
            _ = homeBrowserEntries.popLast()
        }
    }

    /// The native tab bar's re-tap contract: tapping the active tab returns
    /// its transcript to the latest message.
    private func handleTabReselect(_ tab: ConversationTab) {
        switch tab {
        case .group:
            groupScrollToBottom?()
        case .agent:
            agentScrollToBottom?()
        }
    }

    /// True while the Home is showing an open browsing chain: the top bar pops
    /// pages instead of the conversation, and the add-members item hides. The
    /// Home is always behind the sheet, so a chain is browsable at any detent
    /// that leaves it reachable.
    private var isBrowsingHome: Bool {
        !homeBrowserEntries.isEmpty
    }

    @ToolbarContentBuilder
    private var topBarTrailing: some ToolbarContent {
        // Swap the system back button for one that pops browser pages while
        // the home browsing chain is showing, walking home to the root
        // home view.
        if isBrowsingHome {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: popHomeBrowserPage) {
                    Image(systemName: "chevron.left")
                        .fontWeight(.semibold)
                }
                .accessibilityLabel("Back")
                .accessibilityIdentifier("home-browser-back")
            }
        }
        // The embedded Scan/Invite toggle owns scanning, so the lone viewfinder
        // toolbar item is dropped for that flow. Browser pages hide the
        // trailing item entirely.
        if !topBarTrailingHidden && !isBrowsingHome {
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

    /// The in-conversation top-right invite affordance: opens the contacts
    /// invite sheet scoped to this conversation. A single tap, not a menu -
    /// picking who to add is the one thing this button is for, and the invite
    /// sheet carries the link hand-off alongside the picker anyway.
    private var inviteButton: some View {
        Button(action: handleAddFromContactsTap) {
            Image(systemName: "person.crop.circle.badge.plus")
        }
        .disabled(!messagesTopBarTrailingItemEnabled || effectiveReadOnly)
        .accessibilityLabel("Invite")
        .accessibilityIdentifier("add-to-conversation-button")
    }

    /// The payload of the top bar's share button: this conversation's signed
    /// invite link. Empty until the invite hydrates, which is also when the
    /// button is disabled.
    private var inviteShareItems: [Any] {
        let invite = viewModel.invite
        guard !invite.isEmpty else { return [] }
        return [invite.inviteURLString]
    }

    /// A completed share is what keeps a brand-new conversation alive: the
    /// link is out in the world, so the empty-convo teardown must not
    /// reclaim it (see `onInviteShared`).
    private var handleInviteShareCompletion: (UIActivity.ActivityType?, Bool, Error?) -> Void {
        { _, completed, _ in
            guard completed else { return }
            onInviteShared?()
        }
    }

    private var handleAddFromContactsTap: () -> Void {
        { presentingAddFromContactsPicker = true }
    }

    /// Non-nil only for the agent the Agent tab is bound to (the
    /// conversation's first verified agent); anyone else falls back to the
    /// contact card's direct-create path. Hoisted out of the view function
    /// so it stays a single builder expression.
    private func startAgentDmAction(for member: ConversationMember) -> ((String) -> Void)? {
        guard member.profile.inboxId == primaryAgentInboxId else { return nil }
        return { _ in
            viewModel.presentingProfileForMember = nil
            withAnimation(.easeInOut(duration: 0.25)) {
                selectTab(.agent)
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
}

// MARK: - Layout

private extension ConversationView {
    /// The conversation's layered layout: the selected tab's backing view
    /// filling the screen and the floating conversation sheet over it. The
    /// sheet is a bottom-aligned ZStack sibling (not an overlay - safe-area
    /// expansion doesn't reach overlay children), so it can extend into the
    /// bottom safe area like the native tab bar while still riding the
    /// keyboard.
    var conversationLayout: some View {
        ZStack {
            backingViews
            homeBrowserLayers
        }
        .conversationSheetPresentation(
            detent: $sheetDetent,
            chromeHeight: sheetOccupiedChromeHeight,
            lastMessageHeight: lastMessageHeight
        ) {
            conversationSheet
        }
    }

    /// The home browsing chain: full-screen pages sliding in above the
    /// home, below the floating sheet. Like the backing views, the chain
    /// stays mounted across tab switches (hidden, not torn down) so
    /// returning to the Home tab lands back on the same page.
    @ViewBuilder
    var homeBrowserLayers: some View {
        ZStack {
            ForEach(homeBrowserEntries) { entry in
                HomeBrowserPageView(
                    entry: entry,
                    sheetHeight: sheetChromeHeight,
                    onNavigationRequest: { url in
                        pushHomeBrowserPage(for: url)
                    }
                )
                .transition(.move(edge: .trailing))
            }
        }
    }

    /// The permanent backing surface. The Home is no longer a tab: it is what
    /// the conversation *is* behind the sheet, uncovered when the sheet rests
    /// collapsed and progressively hidden as it grows.
    var backingViews: some View {
        HomeLayoutView(
            conversationId: viewModel.conversation.id,
            webURL: viewModel.conversation.spaceURL,
            sheetHeight: sheetChromeHeight,
            onNavigationRequest: { url in
                pushHomeBrowserPage(for: url)
            }
        )
    }

    /// The transcripts the sheet hosts, both kept mounted once visited:
    /// switching flips opacity and hit-testing instead of tearing views down,
    /// so the UIKit collection views keep their scroll state across a tab hop.
    ///
    /// Neither insets for the sheet - inside it, the composer and tab bar are
    /// siblings below rather than chrome floating over the content.
    @ViewBuilder
    var sheetTranscripts: some View {
        ZStack {
            messagesView
                .opacity(selectedTab == .group ? 1 : 0)
                .allowsHitTesting(selectedTab == .group)
            if visitedTabs.contains(.agent), let agentDmSession {
                AgentDmPageView(
                    session: agentDmSession,
                    profileSettingsViewModel: profileSettingsViewModel,
                    extraBottomInset: sheetChromeHeight,
                    isReadOnly: effectiveReadOnly,
                    isActiveTab: selectedTab == .agent,
                    contextMenuState: agentContextMenuState,
                    focusState: $agentFocusState,
                    focusCoordinator: agentFocusCoordinator,
                    onScrollToBottomAvailable: { scrollFn in
                        // Same deferral as the group transcript's bridge.
                        DispatchQueue.main.async {
                            agentScrollToBottom = scrollFn
                        }
                    }
                )
                .opacity(selectedTab == .agent ? 1 : 0)
                .allowsHitTesting(selectedTab == .agent)
            }
        }
    }

    var conversationSheet: some View {
        ConversationSheetContent(
            detent: sheetDetent,
            onChromeHeightChanged: { height in
                sheetChromeHeight = height
            },
            transcriptContent: { sheetTranscripts },
            barContent: { sheetBarContent },
            tabBar: {
                ConversationTabBar(
                    selectedTab: $selectedTab,
                    tabs: availableTabs,
                    badgedTabs: badgedTabs,
                    onReselect: handleTabReselect(_:)
                )
            }
        )
        // The long-press context menu takes the screen; the card fades out
        // under it rather than competing.
        .opacity(contextMenuState.isPresented || agentContextMenuState.isPresented ? 0 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: contextMenuState.isPresented)
        // Scoped to the sheet: the Agent tab's dark surface is the sheet's,
        // not the conversation's, and the Home behind it keeps its own scheme.
        .preferredColorScheme(preferredScheme)
    }

    /// The bar the sheet hosts above its tab bar, keyed by the selected tab:
    /// the group composer, or the agent-DM composer (disabled until the DM
    /// exists).
    @ViewBuilder
    var sheetBarContent: some View {
        switch selectedTab {
        case .group:
            if !effectiveReadOnly {
                ConversationComposerBar(
                    viewModel: viewModel,
                    focusState: $focusState,
                    focusCoordinator: focusCoordinator,
                    messagesTextFieldEnabled: messagesTextFieldEnabled,
                    scrollToBottom: { groupScrollToBottom?() },
                    onDebugAttachmentTap: debugAttachmentTapHandler,
                    extraBarContent: { groupExtraBarContent }
                )
                // Only where there is an agent to govern, and only while the
                // Listen flag is on. Absent, the composer draws no bubble at
                // all.
                .environment(\.agentParticipation, participationContext)
            }
        case .agent:
            if let agentDmSession, !effectiveReadOnly {
                AgentComposerBar(
                    session: agentDmSession,
                    focusState: $agentFocusState,
                    focusCoordinator: agentFocusCoordinator,
                    isReadOnly: effectiveReadOnly,
                    scrollToBottom: { agentScrollToBottom?() }
                )
                // The participation control governs the group room; it has
                // no meaning in a 1:1 agent DM.
                .environment(\.agentParticipation, nil)
            }
        }
    }

    /// Extra rows above the group composer: the injected bottom-bar slot plus
    /// the status slot. The composer lives in the conversation sheet now, so
    /// this is where that pair renders.
    var groupExtraBarContent: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            bottomBarContent()
            bottomBarStatusSlot
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }
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

    func handleInviteCodeChanged(from oldValue: Bool, to newValue: Bool) {
        guard !oldValue, newValue else { return }
        // Opening the code must leave the keyboard down. The composer's first
        // responder lives across the messages view controller's UIKit
        // boundary, so clear both layers: the coordinator (so no focus-restore
        // logic re-raises it) and the actual first responder.
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
            presentingInviteCode: viewModel.presentingInviteCode,
            presentingConversationForked: viewModel.presentingConversationForked,
            presentingExplodedInviteInfo: viewModel.presentingExplodedInviteInfo,
            presentingPaywall: viewModel.presentingPaywall,
            showingAgentsInfo: showingAgentsInfo,
            showingLockedInfo: showingLockedInfo,
            onConversationSettingsChanged: handleConversationSettingsChanged(from:to:),
            onProfileSettingsChanged: handleProfileSettingsChanged(from:to:),
            onInviteCodeChanged: handleInviteCodeChanged(from:to:),
            onConversationForkedChanged: handleConversationForkedChanged(from:to:),
            onExplodedInviteInfoChanged: handleExplodedInviteInfoChanged(from:to:),
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
            presentingNewConvoForInvite: viewModel.presentingNewConversationForInvite != nil,
            presentingAddFromContactsPicker: presentingAddFromContactsPicker,
            onFullInfoChanged: handleFullInfoChanged(from:to:),
            onPhotosInfoChanged: handlePhotosInfoChanged(from:to:),
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
            variantId: FeatureFlags.shared.effectiveAgentVariantSlug,
            service: ConversationAppDataParticipationService(
                metadataWriter: viewModel.conversationMetadataWriter,
                mode: mode
            )
        )
        store.apply(syncedLevel: AgentParticipationLevel(mode: mode))
        participation = store
    }
}

/// Which view occupies the status slot under the composer; also the
/// animation value for the slot's transitions, so the whole slot animates
/// on one Equatable instead of stacking per-branch `.animation` modifiers.
private enum ConversationBottomBarSlot: Equatable {
    case capabilityApprovedToast
    case escalationPrompt(requestId: String)
    case onboarding
}

// MARK: - Bottom bar status slot

private extension ConversationView {
    /// Toast wins, then a pending agent ability-use ask, then onboarding.
    var bottomBarSlot: ConversationBottomBarSlot {
        if viewModel.showsCapabilityApprovedToast {
            return .capabilityApprovedToast
        }
        if let request = escalationViewModel?.pendingRequest {
            return .escalationPrompt(requestId: request.id)
        }
        return .onboarding
    }

    /// The status slot under the composer. Capability requests no longer
    /// auto-present a card here: the transcript's connect pill is the
    /// single entry point for those and opens the approval sheet. The slot
    /// keeps the post-approval toast, the agent ability-use consent card,
    /// and the onboarding view.
    var bottomBarStatusSlot: some View {
        @Bindable var onboardingCoordinator = viewModel.onboardingCoordinator
        return Group {
            switch bottomBarSlot {
            case .capabilityApprovedToast:
                CapabilityApprovedToastView()
                    .transition(.blurReplace)
            case .escalationPrompt:
                if let escalationViewModel {
                    AbilityEscalationPromptSurface(viewModel: escalationViewModel)
                        .transition(.blurReplace)
                }
            case .onboarding:
                ConversationOnboardingView(
                    coordinator: onboardingCoordinator,
                    focusCoordinator: focusCoordinator,
                    coreActions: viewModel.coreActions
                )
                .transition(.blurReplace)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: bottomBarSlot)
    }

    /// Keys the escalation `.task` on the conversation AND on whether it
    /// has an agent, mirroring `participationTaskKey`: a view instance that
    /// pages to another conversation rebuilds the model for the new stream,
    /// and an agent that joins an already-open conversation starts
    /// observation without needing a re-appear.
    var escalationTaskKey: String {
        "\(viewModel.conversation.id)-\(viewModel.conversation.hasAgent)"
    }

    /// Builds the escalation view model when the Abilities V2 flag is on
    /// and the conversation has an agent. The flag is read once and latched
    /// -- same posture as `ConversationInfoView.AgentAccessMode`. Runs from
    /// a `.task` keyed on `escalationTaskKey`, so re-appearance restarts
    /// stream observation and a conversation change rebuilds the model.
    func prepareEscalationIfNeeded() {
        if let escalationViewModel, escalationViewModel.conversationId != viewModel.conversation.id {
            escalationViewModel.stopObserving()
            self.escalationViewModel = nil
        }
        if let escalationViewModel {
            escalationViewModel.startObserving()
            return
        }
        guard FeatureFlags.shared.isAbilitiesV2Enabled,
              viewModel.conversation.hasAgent else {
            return
        }
        let escalation = ConversationEscalationViewModel(
            conversationId: viewModel.conversation.id,
            selection: AbilitiesServices.selection
        )
        escalation.startObserving()
        escalationViewModel = escalation
    }
}
