import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
import SwiftUI
import SwiftUIIntrospect

struct ConversationView<MessagesBottomBar: View>: View {
    @Bindable var viewModel: ConversationViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    /// The group composer's focus, handed down by `ConversationPresenter`
    /// rather than declared here.
    ///
    /// It has to be the shell's own state: the presenter already runs the one
    /// `focusCoordinatorSync` for `focusCoordinator`, and a second sync onto a
    /// local `@FocusState` gives one coordinator two owners. They then fight -
    /// each other's writes land as in-flight transitions, `syncFocusState`
    /// bails out, and a dismissal quietly does nothing.
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    /// The group composer's focus coordinator, shared with the shell so the
    /// conversation-name and display-name editors and the composer all move
    /// focus through one object.
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
    /// An explicit page to open on, overriding the unread heuristic. Set by the
    /// list's "Open Agent DM" / "Open Things" context-menu actions so the open
    /// lands on the chosen tab regardless of which lane holds the unread. Nil
    /// leaves the heuristic in charge.
    var initialTabOverride: ConversationTab?
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
    /// Replaces the window safe-area inset used to position the floating top
    /// chrome. Standalone sheets pass the same fixed inset as their locally
    /// rendered conversation indicator.
    var topChromeInsetOverride: CGFloat?
    @ViewBuilder let bottomBarContent: () -> MessagesBottomBar

    @State private var showingLockedInfo: Bool = false
    @State private var showingFullInfo: Bool = false
    @State private var showingAgentsInfo: Bool = false
    /// Agent participation for this conversation.
    /// It lives here rather than in the composer because the level belongs to
    /// the conversation; the composer only draws the control.
    @State private var participation: AgentParticipationStore?
    /// The conversation sheet's selected tab, the single source of truth for
    /// both the backing view behind the sheet and the bar the sheet hosts.
    @State private var selectedTab: ConversationTab = .group
    /// Guards the one-time seed of `selectedTab` from `initialAgentDmInboxId`.
    @State private var didSeedInitialTab: Bool = false
    /// The in-flight write clearing the group's unread flag, held so a collapse
    /// can abandon it. See `markGroupAsRead`.
    @State private var groupMarkReadTask: Task<Void, Never>?
    /// Each lane's transcript content height, which caps how far the sheet opens
    /// on that lane - see `sheetHeights`.
    ///
    /// Per lane so a tab switch does not have to wait for the incoming transcript
    /// to re-measure. `nil` until measured, which leaves the sheet uncapped rather
    /// than pinned to a transcript of unknown height.
    /// Window safe-area insets, used to convert the sheet's physical-edge
    /// clearance into the safe-area-relative inset the transcripts take.
    @Environment(\.safeAreaInsets) private var windowSafeAreaInsets: EdgeInsets
    /// Binds the Agent tab to the agent's real DM conversation; shared by the
    /// backing transcript and the sheet's agent composer.
    @State private var agentDmSession: AgentDmSession?
    /// Tracks keyboard visibility so tab switches can transfer composer
    /// focus between the group and agent composers.
    @State private var isKeyboardVisible: Bool = false
    /// Set when Context takes the keyboard away, so returning to a transcript
    /// gives it back. Context has no composer, so the keyboard cannot simply
    /// hand over the way it does between Group and Agent - it has to be put
    /// away and remembered, or a glance at the Space costs the user their
    /// keyboard and their place in what they were typing.
    @State private var keyboardParkedByContext: Bool = false
    /// Lifted out of `MessagesView` so this view can hide the conversation
    /// sheet while the long-press context menu is presented.
    @State private var contextMenuState: MessageContextMenuState = .init()
    /// The agent DM transcript's own context-menu state; the DM stays mounted
    /// alongside the group transcript, so they cannot share one.
    @State private var agentContextMenuState: MessageContextMenuState = .init()
    /// The agent composer's focus coordinator, paired with `agentFocus` below.
    @State private var agentFocusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: .compact)
    /// The agent composer's focus, its own field because both transcripts stay
    /// mounted and a shared one would move focus between lanes.
    @FocusState private var agentFocus: MessagesViewInputFocus?
    /// Scroll-to-bottom triggers bridged out of each transcript for the
    /// composers to fire on send.
    @State private var groupScrollToBottom: ((Bool) -> Void)?
    @State private var agentScrollToBottom: ((Bool) -> Void)?
    /// The home browsing chain, layered over the home and below the
    /// floating sheet so browsing never leaves the conversation screen.
    /// While non-empty, the top bar swaps the system back button for one
    /// that pops pages, and hides the add-members item.
    @State private var groupEmptyStateSettled: Bool = false
    @State private var homeBrowserEntries: [HomeBrowserEntry] = []
    @State private var showingDebugInjector: Bool = false
    @State private var presentingAddFromContactsPicker: Bool = false
    /// Non-nil presents the Connections browser modal, carrying the
    /// launching agent DM's context (see `ConnectionsBrowserMode`).
    @State private var connectionsBrowserContext: ConnectionsBrowserMode?
    /// Drives the system share sheet behind the top bar's invite-link button.
    @State private var presentingInviteShareSheet: Bool = false
    @State private var navState: ConversationNavigatorImpl = .init()
    @State private var navigator: ConversationCollector?
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.agentRelayDependencies) private var agentRelayDependencies: AgentRelayDependencies?
    @State private var agentChatDraft: AgentChatDraft?
    @State private var isApplyingComposerDraft: Bool = false

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

    private var topChromeInset: CGFloat {
        topChromeInsetOverride ?? windowSafeAreaInsets.top
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

    // The group transcript's multi-line handlers, named rather than inline so
    // the `MessagesView(...)` call below stays inside the function-length
    // budget.

    private func handleTranscriptUserInteraction() {
        viewModel.dismissQuickEditor()
        focusCoordinator.dismissQuickEditor()
    }

    private func handleTranscriptSendMessage() {
        viewModel.onSendMessage(focusCoordinator: focusCoordinator)
    }

    private func handleTranscriptThinkingIndicatorTap(_ descriptor: ThinkingSessionDescriptor) {
        viewModel.presentingThinkingDetail = descriptor
    }

    private func handleTranscriptReply(_ message: AnyMessage) {
        viewModel.onReply(message)
        focusCoordinator.moveFocus(to: .message)
    }

    /// Reply chosen from the sheet's long-press menu, which is shared by both
    /// transcripts - so it has to be aimed at the lane the message came from
    /// rather than at the group. `handleTranscriptReply` above is the group
    /// transcript's own swipe-to-reply and stays group-only.
    private func handleContextMenuReply(_ message: AnyMessage) {
        activeLaneViewModel.onReply(message)
        activeLaneFocusCoordinator.moveFocus(to: .message)
    }

    private func handleTranscriptOpenMessageDetail(_ message: AnyMessage) {
        viewModel.presentingMessageDetail = message
    }

    private func handleTranscriptCapabilityConnectTap(_ prompt: CapabilityConnectPrompt) {
        // Read-only viewers see the pill but can't answer the request (a result
        // message couldn't be sent on their behalf anyway).
        guard !effectiveReadOnly else { return }
        viewModel.onTapCapabilityConnectPrompt(prompt)
    }

    private func handleTranscriptDisplayNameEndedEditing() {
        viewModel.onDisplayNameEndedEditing(focusCoordinator: focusCoordinator, context: .quickEditor)
    }

    private func messagesView(focus: FocusState<MessagesViewInputFocus?>.Binding) -> some View {
        MessagesView(
            contextMenuState: contextMenuState,
            conversation: viewModel.conversation,
            messages: groupMessages,
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
            focusState: focus,
            focusCoordinator: focusCoordinator,
            messagesTextFieldEnabled: messagesTextFieldEnabled,
            isReadOnly: effectiveReadOnly,
            onUserInteraction: handleTranscriptUserInteraction,
            onSendMessage: handleTranscriptSendMessage,
            onClearInvite: viewModel.clearPendingInvite,
            onClearLinkPreview: { viewModel.pastedLinkPreview = nil },
            onClearMediaAttachment: viewModel.removeMediaAttachment(id:),
            onTapAvatar: viewModel.onTapAvatar(_:),
            onTapInvite: viewModel.onTapInvite(_:),
            onTapAgentShare: viewModel.onTapAgentShare(_:),
            messageLinkRouter: routeSpaceLink(_:),
            conversationSpaceURL: viewModel.conversation.spaceURL,
            agentShareResolver: viewModel.agentShareResolver,
            inviteMembershipResolver: viewModel.inviteMembershipResolver,
            onReaction: viewModel.onReaction(emoji:messageId:),
            onToggleReaction: viewModel.onReaction(emoji:messageId:),
            onTapReactions: viewModel.onTapReactions(_:),
            onTapReadReceipts: viewModel.onTapReadReceipts(_:),
            onTapThinkingIndicator: handleTranscriptThinkingIndicatorTap(_:),
            onReply: handleTranscriptReply(_:),
            onOpenMessageDetail: handleTranscriptOpenMessageDetail(_:),
            expandedMessageIds: viewModel.expandedMessageIds,
            onToggleMessageExpanded: viewModel.toggleMessageExpanded(_:),
            replyingToMessage: viewModel.replyingToMessage,
            replyingToAudioTranscriptText: viewModel.replyingToAudioTranscriptText,
            onCancelReply: viewModel.cancelReply,
            onDisplayNameEndedEditing: handleTranscriptDisplayNameEndedEditing,
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
            onTapCapabilityConnect: handleTranscriptCapabilityConnectTap(_:),
            onRetryMessage: viewModel.retryMessage(_:),
            onDeleteMessage: viewModel.deleteMessage(_:),
            onRetryAgentJoin: { viewModel.retryAgentJoin() },
            onInviteAgent: {},
            onInvitePeople: handleAddFromContactsTap,
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
            extraBottomInset: 0,
            // Clearance for the top chrome the transcript scrolls under. The
            // full chrome, not just the control: this used to inset by the
            // control alone because a leading `.invite` / `.conversationInfo`
            // cell filled the capsule's row, and insetting by both counted it
            // twice. The invite cell is gone, so an inviter has no leading
            // cell and the first message came to rest inside the scrim's
            // full-strength band.
            topContentInset: ConversationChromeMetrics.contentClearance,
            // The transcript hosts its own composer as a bottom safe-area bar.
            // That is what puts the list at full height with content scrolling
            // under the bar and the keyboard: the controller only turns on
            // `contentInsetAdjustmentBehavior = .always` and its keyboard
            // tracking when it owns a bottom bar.
            hostsBottomBar: true,
            hostRendersContextMenu: true,
            onScrollToBottomAvailable: { scrollFn in
                // Fires from inside the representable's make pass; defer the
                // state write out of the view-update transaction or SwiftUI
                // drops it.
                DispatchQueue.main.async {
                    groupScrollToBottom = scrollFn
                }
            },
            bottomBarContent: { groupExtraBarContent }
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

    /// True while the Agent tab is selected. The DM is a fixed 2-member
    /// conversation, so the invite/add-member affordance is hidden there.
    private var isAgentDmPageActive: Bool {
        selectedTab == .agent
    }

    /// Chooses the tab this conversation opens on, once. See
    /// `ConversationTab.initial(available:agentDmRequested:)`.
    private func seedInitialTabIfNeeded() {
        guard !didSeedInitialTab else { return }
        didSeedInitialTab = true
        let tab: ConversationTab
        if let override = initialTabOverride, availableTabs.contains(override) {
            tab = override
        } else {
            let agentDmRequested: Bool = initialAgentDmInboxId != nil
                && initialAgentDmInboxId == primaryAgentInboxId
            tab = ConversationTab.initial(
                available: availableTabs,
                agentDmRequested: agentDmRequested,
                agentDmHoldsTheUnread: agentDmHoldsTheUnread
            )
        }
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

    /// Whether the DM lane is the one holding something to read, so the open lands
    /// there rather than on a group transcript that has nothing new in it.
    ///
    /// Only when the group has nothing of its own: with both unread, the group is
    /// what the list row was for.
    private var agentDmHoldsTheUnread: Bool {
        guard !viewModel.conversation.isUnread else { return false }
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

    /// Switches to a requested tab when the list's "Open Agent DM" / "Open Things"
    /// action targets this conversation while it is already on screen (a fresh
    /// open seeds the tab from `initialTabOverride`, but reselecting the same
    /// conversation is a no-op, so a mounted view has to be told directly).
    /// Ignores requests for another conversation or a tab this one doesn't offer.
    private func handleSelectConversationTabRequest(_ note: Notification) {
        guard let conversationId = note.userInfo?["conversationId"] as? String,
              conversationId == viewModel.conversation.id,
              let rawTab = note.userInfo?["tab"] as? String,
              let tab = ConversationTab(rawValue: rawTab),
              availableTabs.contains(tab),
              tab != selectedTab else {
            return
        }
        selectTab(tab)
    }

    /// Programmatic tab selection. Every page is mounted, so this is only the
    /// write - `onChange(of: selectedTab)` does the rest for taps and swipes
    /// alike.
    private func selectTab(_ tab: ConversationTab) {
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

    /// Every conversation offers all three tabs.
    ///
    /// Context included even before the conversation has a Space: the surface
    /// shows its preparing state there, and a tab that appears once a Space
    /// arrives would resize the control mid-conversation.
    private var availableTabs: [ConversationTab] {
        ConversationTab.allCases
    }

    /// The view model behind the transcript the selected tab is showing.
    ///
    /// The sheet renders one long-press menu over both transcripts, because the
    /// menu has to escape the clip the detent puts on them - so the menu cannot
    /// take its handlers from the transcript that raised it, and has to resolve
    /// the lane itself. Aim an action at the wrong one and it lands in the wrong
    /// conversation: a reaction carrying a DM message's id sent through the
    /// group's view model targets a message the group does not have.
    ///
    /// Falls back to the group when the Agent tab has no DM bound yet, which has
    /// no transcript and so no message to act on.
    private var activeLaneViewModel: ConversationViewModel {
        guard selectedTab == .agent, let dmViewModel = agentDmSession?.dmViewModel else {
            return viewModel
        }
        return dmViewModel
    }

    /// The focus coordinator for the selected lane's composer, so a reply opens
    /// the composer the reply will be sent from.
    private var activeLaneFocusCoordinator: FocusCoordinator {
        selectedTab == .agent ? agentFocusCoordinator : focusCoordinator
    }

    /// Per-tab unread indicators, from the surfaces' own conversations.
    ///
    /// A transcript tab that is selected is being read, so it never badges - the
    /// user is looking at it, and selecting it marked it read (see
    /// `claimReadingLane`). This used to be a weaker claim: the sheet could be
    /// collapsed over the selected transcript, so being selected did not mean
    /// being read and the selected tab badged anyway. Nothing covers a selected
    /// tab now.
    ///
    /// Context is never badged - it has no unread state to carry.
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
        // Losing the Space URL drops any pages browsed from it, but the tab
        // stays: without a URL the Home shows its preparing state rather than
        // moving the user somewhere they did not ask to go.
        .onChange(of: viewModel.conversation.spaceURL) { _, newURL in
            if newURL == nil {
                homeBrowserEntries.removeAll()
            }
        }
        // The new-convo flow swaps a placeholder view model for the real
        // conversation, and the on-screen registration has to follow it: the
        // placeholder's id is the one held otherwise, so the conversation the
        // user is actually looking at keeps raising banners while the
        // placeholder's registration leaks past this screen.
        .onChange(of: viewModel.conversation.id) { oldId, newId in
            handleConversationIdChanged(from: oldId, to: newId)
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
        conversationPresentations(conversationCore)
        .onChange(of: viewModel.messageText) { _, _ in
            // A staged draft can contain a URL but was not pasted by the user.
            guard !isApplyingComposerDraft else {
                isApplyingComposerDraft = false
                return
            }
            viewModel.checkForInviteURL()
            viewModel.checkForAgentShareURL()
            viewModel.checkForPastedLink()
        }
        .animation(.easeOut, value: viewModel.explodeState)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onAppear {
            ensureNavigator()
            applyPendingComposerDraft()
            navState.markScreenAppeared()
            updateGroupOnScreen(isOnScreen: true)
            // Seed before the viewed check: a DM-notification open lands
            // straight on the agent page, and the group must not count as
            // viewed (its unread state and read receipts stay untouched
            // until its tab actually shows). Same when returning from a
            // push while on a non-Group tab.
            seedInitialTabIfNeeded()
            // Opening onto Context means no transcript is being read, so the
            // conversations list's claim is handed straight back - otherwise a
            // message arriving while the user is on the Space would neither
            // badge a tab nor raise a banner. Seeding never picks Context
            // today, but the read state should not depend on that.
            if selectedTab.hostsTranscript {
                claimReadingLane()
            } else {
                releaseReadingLane()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAgentDmPageRequested)) { note in
            handleSelectAgentDmPageRequest(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectConversationTabRequested)) { note in
            handleSelectConversationTabRequest(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationNotificationTapped)) { notification in
            let conversationId: String? = notification.userInfo?["conversationId"] as? String
            if conversationId == viewModel.conversation.id {
                applyPendingComposerDraft()
            }
        }
        .onDisappear {
            viewModel.onConversationDisappeared()
            updateGroupOnScreen(isOnScreen: false)
            // The DM clears its own registration when its page unmounts, which
            // only happens if the Agent tab was ever visited. Clearing from here
            // too covers the conversation that binds a DM and never shows it.
            agentDmSession?.updateDmOnScreen(isOnScreen: false)
            navigator?.closed(context: navState.closeContext())
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
        .toolbar { topBarTrailing }
        .onDisappear {
            VoiceMemoPlayer.shared.stop()
            viewModel.voiceMemoRecorder.cancelRecording()
        }
    }

    private func applyPendingComposerDraft() {
        let previousText = viewModel.messageText
        isApplyingComposerDraft = true
        viewModel.applyPendingComposerDraft()
        if viewModel.messageText == previousText {
            isApplyingComposerDraft = false
        }
    }
}

// MARK: - Presentations

private extension ConversationView {
    /// Every sheet the conversation raises, applied to `body`.
    ///
    /// They used to hang off the conversation sheet's content instead, and had
    /// to: the sheet was presented for as long as the screen was up, a view
    /// controller presents one thing at a time, and a second presentation asked
    /// for from the same host was simply refused - taps on a reaction or a read
    /// receipt did nothing at all. With the sheet gone the screen's own
    /// presentation slot is free, so these sit where they belong again.
    ///
    /// Split across three functions purely to keep each one inside the
    /// type-check budget and the body-length limit.
    @ViewBuilder
    func conversationPresentations(_ content: some View) -> some View {
        let connectionContent = connectionsBrowserPresentation(content)
        let conversationContent = conversationLevelPresentations(connectionContent)
        let messageContent = messagePresentations(conversationContent)
        agentChatPresentation(messageContent)
    }

    @ViewBuilder
    func agentChatPresentation(_ content: some View) -> some View {
        content.sheet(item: $agentChatDraft) { draft in
            if let agentRelayDependencies {
                NavigationStack {
                    AgentChatView(
                        provider: draft.provider,
                        dependencies: agentRelayDependencies,
                        session: viewModel.session,
                        initialText: draft.text
                    )
                }
            }
        }
    }

    /// The Connections browser, raised full-screen by the agent composer's
    /// powerplug. Its own function so `conversationLevelPresentations` stays
    /// inside the type-check budget it was already split to respect.
    @ViewBuilder
    func connectionsBrowserPresentation(_ content: some View) -> some View {
        content
            .fullScreenCover(item: $connectionsBrowserContext) { mode in
                AbilitiesListScreen(
                    selection: AbilitiesServices.selection,
                    mode: mode,
                    usageSource: AbilitiesServices.connectionUsageSource
                )
            }
    }

    /// The sheets the conversation itself raises, as opposed to the ones a
    /// message raises. Split from `messagePresentations` only to keep each
    /// function inside the type-check budget and the body-length limit.
    @ViewBuilder
    func conversationLevelPresentations(_ content: some View) -> some View {
        content
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
            .debugConnectionInjectorSheet(
                isPresented: debugInjectorBinding,
                conversationId: viewModel.conversation.id,
                messagingService: viewModel.messagingService
            )
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
    }

    /// The sheets a message raises - a tray, a detail, a member's card.
    @ViewBuilder
    func messagePresentations(_ content: some View) -> some View {
        content
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
                    onStop: { Task { await viewModel.interruptAgent() } },
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
        transferKeyboard(to: newTab)
        // A right-swipe can both start a reply and switch away; cancel the
        // in-flight reply swipe so the tab change doesn't fire one.
        // A right-swipe can both start a reply and carry the pager to another
        // tab. Cancel the in-flight swipe on the lane being left so the tab
        // change never lands a reply, and on the one being entered so a partial
        // drag does not survive into it.
        contextMenuState.cancelInFlightSwipe()
        agentContextMenuState.cancelInFlightSwipe()
        // The group is "being viewed" only while its tab is selected. Off
        // the tab, read receipts must stop (the user isn't reading the
        // transcript) and the group has to leave the active-conversation
        // gate so incoming messages mark it unread and badge its tab.
        if oldTab == .group, newTab != .group {
            handleGroupTabLeft()
        }
        // Landing on a transcript means it is being read: claim its lane and
        // clear whatever badged while the user was elsewhere. Claiming, not just
        // registering the lane - `claimReadingLane` is what also runs
        // `markGroupAsRead`, so arriving on an unread Group clears the flag
        // rather than leaving the row bold behind a transcript the user is
        // looking at.
        if newTab.hostsTranscript {
            claimReadingLane()
            scrollTranscriptToBottom(newTab, animated: false)
        } else if oldTab == .group {
            // Leaving the Group for Context. `handleGroupTabLeft` above owns the
            // group's deactivation and has to do it *after* its asynchronous
            // `setUnread(false)` lands; releasing the group lane here too would
            // deactivate it first, so a message arriving in that window would be
            // marked unread and then wiped by the stale write. Only the agent
            // lane is handed back here.
            agentDmSession?.cancelPendingReadMark()
            agentDmSession?.updateActiveDmLane(isActive: false)
        } else {
            releaseReadingLane()
        }
    }

    /// Moves the keyboard with the selected tab.
    ///
    /// Between the two transcripts it hands over: the incoming composer is
    /// claimed directly, because the outgoing field resigns implicitly and its
    /// sync wiring clears its coordinator - explicitly dismissing first leaves a
    /// beat with no first responder and the keyboard visibly dips.
    ///
    /// Context has no composer to hand it to, so the keyboard is put away and
    /// the fact that it was up is remembered. Returning to either transcript
    /// gives it back, so stepping over to the Space and back does not cost the
    /// user their keyboard.
    private func transferKeyboard(to newTab: ConversationTab) {
        let keyboardWasUp: Bool = isKeyboardVisible
        guard newTab.hostsComposer else {
            keyboardParkedByContext = keyboardWasUp
            // Both layers, the same way `handleInviteCodeChanged` does it. The
            // composer's first responder lives across the messages view
            // controller's UIKit boundary, and SwiftUI's focus state does not
            // always reflect it: a composer focused by a plain tap can leave
            // both coordinators reading nil while the keyboard is up, so
            // writing nil over nil changes nothing and resigns nothing.
            // `moveFocus(to:)` rather than `dismissMessageComposerIfNeeded`,
            // which is guarded on that same unreliable `currentFocus`.
            focusCoordinator.moveFocus(to: nil)
            agentFocusCoordinator.moveFocus(to: nil)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            return
        }
        let shouldFocus: Bool = keyboardWasUp || keyboardParkedByContext
        keyboardParkedByContext = false
        let incoming: FocusCoordinator = newTab == .agent ? agentFocusCoordinator : focusCoordinator
        let outgoing: FocusCoordinator = newTab == .agent ? focusCoordinator : agentFocusCoordinator
        if shouldFocus {
            incoming.moveFocus(to: .message)
        } else {
            outgoing.dismissMessageComposerIfNeeded()
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

    /// The sheet collapsed over the transcript, so nobody is reading it.
    ///
    /// Hands back the selected lane's claim on being read, which is what makes a
    /// message arriving now mark its lane unread and badge its tab - the claim
    /// exists precisely to suppress that. Read receipts stop for the same reason:
    /// the user is not looking at the transcript.
    ///
    /// Deliberately marks nothing read. What arrives while the sheet is down is
    /// unread, and staying unread is the whole point.
    private func releaseReadingLane() {
        // Both lanes, not just the selected one: an in-flight read mark from
        // either would clear an unread that arrives once the sheet is down.
        groupMarkReadTask?.cancel()
        agentDmSession?.cancelPendingReadMark()
        switch selectedTab {
        case .group:
            if viewModel.isViewingConversation {
                viewModel.onConversationDisappeared()
            }
            updateActiveGroupLane(isActive: false)
        case .agent:
            agentDmSession?.updateActiveDmLane(isActive: false)
        case .context:
            // Whichever lane was being read has already been left; release both
            // rather than guess which one the user came from.
            if viewModel.isViewingConversation {
                viewModel.onConversationDisappeared()
            }
            updateActiveGroupLane(isActive: false)
            agentDmSession?.updateActiveDmLane(isActive: false)
        }
    }

    /// The sheet came up off `collapsed`, so the selected lane is being read
    /// again: it reclaims the gate, and whatever badged while the sheet was down
    /// is marked read, because the user is looking at it now.
    ///
    /// Claim before clearing, not after - a message landing between the two would
    /// otherwise mark the lane unread and then be wiped by the clear.
    private func claimReadingLane() {
        switch selectedTab {
        case .group:
            viewModel.onConversationAppeared()
            updateActiveGroupLane(isActive: true)
            markGroupAsRead()
        case .agent:
            agentDmSession?.updateActiveDmLane(isActive: true)
            agentDmSession?.markDmAsRead()
        case .context:
            // Nothing to read on the Space page.
            break
        }
    }

    /// Clears the group's unread flag, abandoning the write if the lane stops
    /// being read before it lands.
    ///
    /// The cancellation is the point. Without it the write outlives its reason:
    /// the sheet collapses, a message arrives and marks the group unread, and the
    /// stale `setUnread(false)` then clears an unread the user never saw. The
    /// tab-leaving path guards the same race by re-checking the selected tab.
    private func markGroupAsRead() {
        let conversationId: String = viewModel.conversation.id
        let messagingService = viewModel.messagingService
        groupMarkReadTask?.cancel()
        groupMarkReadTask = Task {
            do {
                try await messagingService
                    .conversationLocalStateWriter()
                    .setUnread(false, for: conversationId)
            } catch {
                Log.warning("Failed marking group as read: \(error.localizedDescription)")
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

    /// Registers the group as on screen, which is what silences its banners.
    ///
    /// Separate from `updateActiveGroupLane`, which says the group is the lane
    /// being *read* and goes false on a tab change or a collapse. A banner has to
    /// stay suppressed through both: the conversation is still in front of the
    /// user, and the tab's unread dot is the better notification. The DM lane
    /// registers itself the same way - see `AgentDmSession`.
    private func updateGroupOnScreen(isOnScreen: Bool) {
        postOnScreenConversation(viewModel.conversation.id, isOnScreen: isOnScreen)
    }

    /// Moves the registration when the group's own id changes under it, which the
    /// new-convo flow does when the real conversation replaces the placeholder.
    /// Deregister first, so the outgoing id cannot be left behind.
    private func handleConversationIdChanged(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        postOnScreenConversation(oldId, isOnScreen: false)
        postOnScreenConversation(newId, isOnScreen: true)
    }

    private func postOnScreenConversation(_ conversationId: String, isOnScreen: Bool) {
        NotificationCenter.default.post(
            name: .onScreenConversationChanged,
            object: nil,
            userInfo: [
                "conversationId": conversationId,
                "isOnScreen": isOnScreen,
            ]
        )
    }

    /// Takes a link into this conversation's own Space out of the browser and
    /// into the Home behind the sheet, and reports whether it did.
    ///
    /// The sheet settles at `compact` rather than dropping out of the way
    /// entirely: the page is what the tap asked for, but the conversation it
    /// came from is the reason the page matters, and `compact` is the size that
    /// shows both. Both moves start in the same turn, so the push animates
    /// while the sheet resizes instead of after it.
    ///
    /// A pushed page rather than a reload of the Home's own web view, which is
    /// what an in-page link tap already does (see `HomeWebNavigation`): the
    /// same URL should land the same way whether it was tapped in the
    /// transcript or inside the Space, and the page brings the back chevron
    /// and the edge swipe with it.
    private func routeSpaceLink(_ url: URL) -> Bool {
        guard let spaceURL = viewModel.conversation.spaceURL,
              SpaceLink.matches(url, space: spaceURL) else {
            return false
        }
        showContextForSpaceLink()
        if SpaceLink.isRoot(url, space: spaceURL) {
            // The root *is* the Home. Walk any open chain back to it rather
            // than stacking a second copy on top of itself.
            homeBrowserEntries.removeAll()
        } else if !isShowingHomeBrowserPage(for: url) {
            pushHomeBrowserPage(for: url)
        }
        return true
    }

    /// Shows the page a Space link just opened, which now means selecting the
    /// Context tab - that is where Space pages live.
    ///
    /// Focus goes first: a keyboard left standing would cover the page the tap
    /// asked to see, and the outgoing composer is not the one being switched
    /// to.
    private func showContextForSpaceLink() {
        focusCoordinator.dismissMessageComposerIfNeeded()
        agentFocusCoordinator.dismissMessageComposerIfNeeded()
        selectTab(.context)
    }

    /// Whether the page on top of the browsing chain is already showing this
    /// exact location, in which case the tap has nowhere to go and only the
    /// sheet moves. Pushing would stack the page on itself and leave a back
    /// chevron that returns to an identical screen.
    ///
    /// The anchor counts. `/goals` and `/goals#today` are one page but two
    /// places in it, and nothing here can scroll a page that is already open -
    /// so a link to the anchor is pushed, and lands on it, rather than being
    /// swallowed as somewhere the reader already is.
    private func isShowingHomeBrowserPage(for url: URL) -> Bool {
        guard let current = homeBrowserEntries.last else { return false }
        return SpaceLink.isSameLocation(current.url, as: url)
    }

    private func pushHomeBrowserPage(for url: URL) {
        homeBrowserEntries.append(HomeBrowserEntry(url: url))
    }

    /// Walks one page back. The stack animates it, and an edge swipe does the
    /// same thing without coming through here at all.
    private func popHomeBrowserPage() {
        guard !homeBrowserEntries.isEmpty else { return }
        homeBrowserEntries.removeLast()
    }

    /// Promotes focus onto the tab whose composer just took it.
    ///
    /// The system raises the keyboard over whatever is on screen; if that was
    /// the Context tab, the composer that took focus belongs to a tab the user
    /// is not looking at. Selecting it keeps what is on screen in step with
    /// what is being typed into.
    private func handleComposerFocusChanged(_ focus: MessagesViewInputFocus?) {
        guard focus == .message, !selectedTab.hostsTranscript else { return }
        selectTab(.group)
    }

    /// Returns a transcript to its newest message.
    ///
    /// `animated: false` for everything the sheet drives. An animated scroll is
    /// for a send, where the user is watching their message arrive; a reset the
    /// sheet performs on a transcript it has collapsed over is housekeeping, and
    /// animating it only risks the motion being seen.
    private func scrollTranscriptToBottom(_ tab: ConversationTab, animated: Bool) {
        switch tab {
        case .group:
            groupScrollToBottom?(animated)
        case .agent:
            agentScrollToBottom?(animated)
        case .context:
            break
        }
    }

    private func scrollActiveTranscriptToBottom(animated: Bool = true) {
        scrollTranscriptToBottom(selectedTab, animated: animated)
    }

    /// True while the Context tab is showing an open browsing chain: the top bar
    /// pops pages instead of the conversation, and the add-members item hides.
    ///
    /// Scoped to the selected tab, not just to the chain. The Space used to sit
    /// behind the sheet where it was always the thing on screen, so an open
    /// chain always meant the user was in it. It is a tab now: leaving Context
    /// with pages still pushed would keep the bar in browser mode over a
    /// transcript, where its Back button pops a stack nobody can see instead of
    /// leaving the conversation. The chain is kept rather than cleared, so
    /// coming back to Context returns to the page they were on.
    private var isBrowsingHome: Bool {
        selectedTab == .context && !homeBrowserEntries.isEmpty
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
        { activityType, completed, _ in
            ConversationShareReporter.report(
                activityType: activityType,
                completed: completed,
                invite: viewModel.invite,
                conversation: viewModel.conversation,
                coreActions: viewModel.coreActions,
                session: viewModel.session
            )
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
                isApproving: viewModel.capabilityApprovalInFlight,
                approvalErrorMessage: viewModel.capabilityApprovalErrorMessage,
                scopeDisplayName: viewModel.capabilityApprovalScopeName,
                blockedMessage: viewModel.capabilityApprovalBlockedMessage,
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
    /// The conversation's layout: the selected tab's page filling the screen,
    /// with the top chrome floating over it.
    ///
    /// This used to be the Space surface with a permanently-presented sheet over
    /// it holding the transcripts. The sheet is gone, and with it the detent that
    /// decided how much Space showed, the geometry the two sides traded, and the
    /// focus host a presentation boundary made necessary. The Space is a tab now.
    var conversationLayout: some View {
        ZStack(alignment: .top) {
            pageHost
            // The wash is its own layer, not the chrome's background: it runs
            // taller than the chrome's frame and a background would clip it.
            ConversationChromeScrim(topSafeAreaInset: topChromeInset)
            ConversationTopChrome(topSafeAreaInset: topChromeInset) {
                ConversationSegmentedControl(
                    selectedTab: $selectedTab,
                    tabs: availableTabs,
                    badgedTabs: badgedTabs
                )
            }
        }
        .overlay { messageContextMenuOverlay }
        // The agent composer's own state mirrors its own coordinator. Without
        // it, `FocusCoordinator.moveFocus` still runs and still updates the
        // coordinator, but nothing takes first responder. The group composer
        // needs no sync here - it rides the shell's `focusState`, which
        // `ConversationPresenter` already syncs to `focusCoordinator`. Adding a
        // second one for the same coordinator is what broke dismissal.
        .focusCoordinatorSync(
            focusState: $agentFocus,
            coordinator: agentFocusCoordinator,
            resetToken: viewModel.conversation.id
        )
        // The Agent tab is a dark surface. Scoped to this screen's own
        // controller rather than preferred at the window, so the conversations
        // list behind it is not dark for the length of the pop animation (see
        // ScreenAppearanceScope).
        .background {
            ScreenAppearanceScope(style: selectedTab == .agent ? .dark : .unspecified)
                .frame(width: 0, height: 0)
        }
        .onChange(of: focusCoordinator.currentFocus) { _, newFocus in
            handleComposerFocusChanged(newFocus)
        }
        .onChange(of: agentFocusCoordinator.currentFocus) { _, newFocus in
            handleComposerFocusChanged(newFocus)
        }
    }

    /// The three pages, and the composer under whichever of them has one.
    ///
    /// The transcripts stay mounted once visited - switching flips opacity and
    /// hit-testing rather than tearing views down, so the UIKit collection views
    /// keep their scroll state across a tab hop. Context is mounted the same way,
    /// so a Space page is not reloaded every time the user looks away.
    @ViewBuilder
    var pageHost: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(availableTabs) { tab in
                        page(for: tab)
                            // Sized against the scroll view's container rather than
                            // a `GeometryReader`: the reader measures zero on the
                            // first layout pass, which left every page zero-width
                            // and the pager resting on the last one instead of the
                            // tab the conversation opened on.
                            .containerRelativeFrame(.horizontal)
                            .id(tab)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: pagerSelection)
            // A long-press menu owns the screen while it is up, and a drag that
            // paged out from under it would leave the menu pointing at a message
            // on another tab.
            .scrollDisabled(isPagingDisabled)
            .introspect(.scrollView, on: .iOS(.v26)) { (scrollView: UIScrollView) in
                scrollView.bounces = false
            }
            .onChange(of: didSeedInitialTab, initial: false) { _, seeded in
                guard seeded else { return }
                realignPagerAfterSeeding(using: proxy)
            }
        }
    }

    /// Snaps the pager onto the seeded tab once the scroll view has laid out.
    ///
    /// Seeding sets `selectedTab` in `onAppear`, before the pager finishes its
    /// first layout, so `scrollPosition` scrolls toward the target while paging
    /// is still settling. A tab two pages from the default (Things sits past
    /// Agent) can settle the pager on the page in between while the state still
    /// reads the target - the segmented control shows the seeded tab but the
    /// wrong page is on screen. Re-driving the offset once through the scroll
    /// proxy, after this layout pass, lands the page the state already points at.
    private func realignPagerAfterSeeding(using proxy: ScrollViewProxy) {
        let target: ConversationTab = selectedTab
        guard target != .group else { return }
        // The pager's container measures zero on its first layout pass, so the
        // seed's `scrollPosition` can settle on an intermediate page (Things sits
        // past Agent), and the Space page finishes laying out a beat later still.
        // Re-assert the offset across the next few frames until the late layout
        // has caught up; once the pager is on the target the scroll is a no-op,
        // and the guard leaves a user who swiped away in that window alone.
        let delays: [Double] = [0, 0.1, 0.2, 0.35, 0.5, 0.75]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard selectedTab == target else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(target, anchor: .leading)
                }
            }
        }
    }

    /// The pager's position, bridged onto the tab the rest of the screen reads.
    /// Writes land the same way a tap on the segmented control does, so a swipe
    /// and a tap go through one path.
    private var pagerSelection: Binding<ConversationTab?> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                guard let newValue, newValue != selectedTab else { return }
                selectedTab = newValue
            }
        )
    }

    /// True while either transcript has its long-press menu up.
    private var isPagingDisabled: Bool {
        contextMenuState.isPresented || agentContextMenuState.isPresented
    }

    @ViewBuilder
    private func page(for tab: ConversationTab) -> some View {
        switch tab {
        case .group: groupPage
        case .agent: agentPage
        case .context: contextPage
        }
    }

    private var groupPage: some View {
        messagesView(focus: $focusState)
            .task {
                // Messages arrive just after the page appears, so an
                // isEmpty-only gate would flash the empty state open and shut
                // on every conversation that has any. Wait for the first
                // emission to settle before it is allowed to show at all.
                try? await Task.sleep(for: .milliseconds(300))
                groupEmptyStateSettled = true
            }
    }

    /// Gated on `groupEmptyStateSettled` so it can only appear once the
    /// transcript has had a chance to deliver its first messages. Hides on
    /// any item in the list - including a system item like "you joined" or
    /// "earlier messages are hidden" - not just a real message.
    private var showsGroupEmptyState: Bool {
        selectedTab == .group && groupEmptyStateSettled && !viewModel.hasAnyMessagesListItems
    }

    private var groupMessages: [MessagesListItemType] {
        guard showsGroupEmptyState else {
            return viewModel.messagesWithThinkingIndicators
        }
        let isInviteEnabled: Bool = messagesTopBarTrailingItemEnabled && !effectiveReadOnly
        return [.groupEmptyState(isInviteEnabled: isInviteEnabled)]
    }

    @ViewBuilder
    private var agentPage: some View {
        if let agentDmSession {
            let isActive: Bool = selectedTab == .agent
            AgentDmPageView(
                session: agentDmSession,
                profileSettingsViewModel: profileSettingsViewModel,
                extraBottomInset: 0,
                connectionsEnabled: composerConnectionsEnabled,
                onConnectionsTap: handleComposerConnectionsTap,
                isReadOnly: effectiveReadOnly,
                sendButtonPaused: participation?.level == .paused,
                onUnpauseAgent: {
                    // A removed or stale (read-only) device must not be able to
                    // change participation, same gate as the composer's sends.
                    guard !effectiveReadOnly, let participation else { return }
                    // Unpause resumes into listen mode, not full speak-freely.
                    Task { await participation.set(.mentionsOnly) }
                },
                isActiveTab: isActive,
                contextMenuState: agentContextMenuState,
                focusState: $agentFocus,
                focusCoordinator: agentFocusCoordinator,
                messageLinkRouter: routeSpaceLink(_:),
                conversationSpaceURL: viewModel.conversation.spaceURL,
                onScrollToBottomAvailable: { scrollFn in
                    // Same deferral as the group transcript's bridge.
                    DispatchQueue.main.async {
                        agentScrollToBottom = scrollFn
                    }
                },
            )
        }
    }

    /// The Context tab: the conversation's Space page, in a navigation stack of
    /// its own so a link tapped inside it pushes without leaving the
    /// conversation. The stack wraps this page only - the chrome is a sibling
    /// above it, so pushing a page never slides the segmented control away.
    @ViewBuilder
    private var contextPage: some View {
        HomeBrowserNavigationHost(
            entries: $homeBrowserEntries,
            root: { AnyView(spaceSurface) },
            page: { entry in AnyView(homeBrowserPage(for: entry)) }
        )
        .ignoresSafeArea()
    }

    /// One page in the Context tab's browsing chain.
    @ViewBuilder
    func homeBrowserPage(for entry: HomeBrowserEntry) -> some View {
        HomeBrowserPageView(
            entry: entry,
            onNavigationRequest: { url in
                pushHomeBrowserPage(for: url)
            },
            bridgeNavigation: homeBridgeNavigation
        )
    }

    /// The Context tab's root: the conversation's Space web surface.
    @ViewBuilder
    var spaceSurface: some View {
        // A Space is something the agent builds, so with no agent there is
        // nothing here to wait for - the preparing state would spin forever.
        // The tab offers the same way in as the Agent tab does, from the same
        // signal, so the two never disagree about whether one is missing.
        if agentDmSession?.hasNoAgent == true {
            AddAgentPromptView(
                onAddAgent: { agentDmSession?.requestAgentJoin() },
                accessibilityIdentifier: "context-add-agent-button"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, ConversationChromeMetrics.contentClearance)
            .background {
                ZStack {
                    Color.colorBackgroundSurfaceless
                    Color.colorBackgroundSubtle
                }
                .ignoresSafeArea()
            }
            .accessibilityIdentifier("context-no-agent")
        } else {
            HomeLayoutView(
                webURL: viewModel.conversation.spaceURL,
                onNavigationRequest: { url in
                    pushHomeBrowserPage(for: url)
                },
                bridgeNavigation: homeBridgeNavigation
            )
        }
    }

    /// Native destinations for the home page's `window.convos` invite/chat
    /// calls, mirroring Android's `DesktopBridgeNavigation` wiring in
    /// `ConversationScreen`. Each closure reads live state when invoked: the
    /// bridge holds one instance per web view, refreshed on every update pass.
    private var homeBridgeNavigation: HomeBridgeNavigation {
        HomeBridgeNavigation(
            showShareSheet: {
                // Same gate as the native invite controls: a stale/removed
                // device or pending-invite conversation can't mint or share.
                guard inviteActionsEnabled else {
                    Log.warning("HomeBridgeNavigation showShareSheet ignored; invite actions disabled")
                    return
                }
                // Same routing as the composer's "Invite friends": a full
                // conversation can't mint invites and explains itself instead.
                if viewModel.isFull {
                    showingFullInfo = true
                } else {
                    presentingInviteShareSheet = true
                }
            },
            showScan: { onScanInviteCode() },
            showInviteCode: {
                guard inviteActionsEnabled else {
                    Log.warning("HomeBridgeNavigation showInviteCode ignored; invite actions disabled")
                    return
                }
                Log.info("HomeBridgeNavigation wired showInviteCode closure invoked; forwarding to viewModel")
                viewModel.showInviteCode()
            },
            showInvitePicker: {
                guard inviteActionsEnabled else {
                    Log.warning("HomeBridgeNavigation showInvitePicker ignored; invite actions disabled")
                    return
                }
                presentingAddFromContactsPicker = true
            },
            showMembersList: { viewModel.presentingConversationSettings = true },
            // Same destination the member card's agent action opens, so the
            // web surface and the native one agree on what "the agent DM" is.
            showAgentDm: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    selectTab(.agent)
                }
            }
        )
    }

    /// The single host seam for the composer's connections capability: the
    /// `+` menu row and the browser modal both feed from this one read.
    /// Which services a conversation can actually use is decided per
    /// environment by the backend and agent runtime, not the client.
    var composerConnectionsEnabled: Bool {
        true
    }

    /// Powerplug tap from the `+` menu row: presents the Connections
    /// browser full-screen, carrying the launching DM's conversation,
    /// agent inbox id and agent name so its Connected section can scope
    /// its toggles. Guarded by the same capability that offered the row.
    func handleComposerConnectionsTap() {
        guard composerConnectionsEnabled,
              let agentDmSession,
              let agentInboxId = agentDmSession.agentInboxId,
              let dmConversationId = agentDmSession.dmViewModel?.conversation.id else {
            return
        }
        connectionsBrowserContext = .composerModal(
            conversationId: dmConversationId,
            agentInboxId: agentInboxId,
            agentDisplayName: agentDmSession.agentName
        )
    }

    /// The message long-press menu for whichever transcript raised it, layered
    /// at the sheet's root.
    ///
    /// Both transcripts keep their own menu state, and only the selected tab's
    /// can be showing - it is the selected tab the user long-pressed in. The
    /// transcripts themselves render no menu (`hostRendersContextMenu`): inside
    /// the sheet they are clipped to the current detent, which would crop it.
    @ViewBuilder
    var messageContextMenuOverlay: some View {
        let state: MessageContextMenuState = selectedTab == .agent
            ? agentContextMenuState
            : contextMenuState
        let lane: ConversationViewModel = activeLaneViewModel
        MessageContextMenuOverlay(
            state: state,
            isReadOnly: effectiveReadOnly,
            onReaction: lane.onReaction(emoji:messageId:),
            onReply: handleContextMenuReply(_:),
            onCopy: { text in
                UIPasteboard.general.string = text
            },
            onCopyToAgent: copyToAgentAction(state: state, lane: lane)
        )
        .environment(\.agentShareResolver, lane.agentShareResolver)
        .environment(\.inviteMembershipResolver, lane.inviteMembershipResolver)
        // The menu renders in its own tree at the sheet's root, so it inherits
        // nothing from the cells: a link tapped in a bubble's menu preview
        // routes where the bubble's own tap routes only because of this.
        .environment(\.messageLinkRouter, routeSpaceLink(_:))
        .environment(\.conversationSpaceURL, viewModel.conversation.spaceURL)
    }

    func copyToAgentAction(
        state: MessageContextMenuState,
        lane _: ConversationViewModel
    ) -> ((String) -> Void)? {
        guard FeatureFlags.shared.agentRelayEnabled,
              let dependencies = agentRelayDependencies,
              let provider = dependencies.connectionStore.activeProvider,
              (try? dependencies.connectionStore.load(provider: provider)) != nil else {
            return nil
        }
        return { text in
            guard state.presentedMessage != nil else { return }
            agentChatDraft = AgentChatDraft(provider: provider, text: text)
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

    var body: some View {
        let messagingService = viewModel.messagingService
        let contactsRepository = messagingService.contactsRepository()
        let contactsWriter = messagingService.contactsWriter()
        let resolvedContact = Contact.resolved(
            member: member,
            in: viewModel.conversation.id,
            contactsRepository: contactsRepository
        )
        // Closing the sheet is `ContactDetailView`'s job - it dismisses itself
        // once the removal lands and reports the failure otherwise, so every
        // entry point behaves the same.
        let onRemove: () async throws -> Void = { try await viewModel.remove(member: member) }
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

    /// Whether the invite/share affordances may fire. Mirrors the exact gate
    /// the native `inviteButton` uses (`.disabled(!messagesTopBarTrailingItemEnabled
    /// || effectiveReadOnly)`), so a stale/removed device or a pending-invite
    /// conversation can't mint or share invites. The Home web bridge routes its
    /// invite closures through this same read rather than re-deriving the rule.
    private var inviteActionsEnabled: Bool {
        messagesTopBarTrailingItemEnabled && !effectiveReadOnly
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
            isLoading: !participation.hasLoaded,
            agentName: participationAgentName
        ) { level in
            Task { await participation.set(level) }
        }
    }

    /// The name shown in the Listen level's caption. A room with several agents
    /// uses the first one's name to stand for them; falls back to "Agent" when
    /// no agent member is resolved yet.
    var participationAgentName: String {
        viewModel.conversation.members.first(where: \.isAgent)?.displayName ?? "Agent"
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
        guard viewModel.conversation.members.contains(where: \.isAgent) else {
            participation = nil
            return
        }
        let mode = viewModel.conversation.participationMode
        let store = AgentParticipationStore(
            conversationId: viewModel.conversation.id,
            variantId: viewModel.conversationAgentVariantSlug,
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
    case onboarding
}

// MARK: - Bottom bar status slot

private extension ConversationView {
    /// Toast wins, then onboarding.
    var bottomBarSlot: ConversationBottomBarSlot {
        if viewModel.showsCapabilityApprovedToast {
            return .capabilityApprovedToast
        }
        return .onboarding
    }

    /// The status slot under the composer. Capability requests no longer
    /// auto-present a card here: the transcript's connect pill is the
    /// single entry point for those and opens the approval sheet. The slot
    /// keeps the post-approval toast and the onboarding view.
    var bottomBarStatusSlot: some View {
        @Bindable var onboardingCoordinator = viewModel.onboardingCoordinator
        return Group {
            switch bottomBarSlot {
            case .capabilityApprovedToast:
                CapabilityApprovedToastView()
                    .transition(.blurReplace)
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
}
