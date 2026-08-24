import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
import SwiftUI

private struct AgentShareDraft: Identifiable {
    let id: UUID = UUID()
    let text: String
    let conversations: [Conversation]
}

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
    /// When set (and that agent has a DM page), the shell opens on the agent's
    /// DM page instead of the group. Reserved for an explicit agent action or
    /// agent-DM notification; a regular Convo tap always opens Group.
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
    /// Lets a host replace this pushed Convo with another one while keeping an
    /// agent result as an editable group draft. Nil in standalone creation
    /// flows, where the picker keeps the current Convo as its destination.
    var onStageTextInConversation: ((String, Conversation) -> Void)?
    @ViewBuilder let bottomBarContent: () -> MessagesBottomBar

    @State private var showingLockedInfo: Bool = false
    @State private var showingFullInfo: Bool = false
    @State private var showingAgentsInfo: Bool = false
    /// Agent participation for this conversation, behind the Listen debug flag.
    /// It lives here rather than in the composer because the level belongs to
    /// the conversation; the composer only draws the control.
    @State private var participation: AgentParticipationStore?
    /// Pause is the moment privacy intent is clearest. When no timer is active
    /// and the per-conversation automation is off, this presents one bounded
    /// choice: pause only, or pause and enable the remembered timer.
    @State private var showingPausePrivacyPrompt: Bool = false
    @State private var disappearingMessagesError: String?
    @State private var showingMessageDeleteConfirmation: Bool = false
    @State private var isDeletingSelectedMessages: Bool = false
    @State private var messageDeletionError: String?
    /// The selected full-screen surface, shared by the content and top switcher.
    @State private var selectedTab: ConversationTab = .group
    /// Tabs the user has visited. The agent DM mounts on first visit and stays
    /// mounted (hidden, not torn down) so tab switches never reload it.
    @State private var visitedTabs: Set<ConversationTab> = [.group]
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
    /// The scheme the conversation is presented in, sampled while the Agent
    /// tab is not forcing its own. See `preferredScheme`.
    @Environment(\.colorScheme) private var presentedColorScheme: ColorScheme
    @State private var ambientColorScheme: ColorScheme?
    /// Binds the Agent tab to the agent's real DM conversation; shared by the
    /// backing transcript and the sheet's agent composer.
    @State private var agentDmSession: AgentDmSession?
    /// Owns the Firebase-only switcher, lane drafts, demo messages, and
    /// in-flight prototype replies. Production never renders it.
    @State private var agentChatPrototypeState: AgentChatPrototypeState = .init()
    @AppStorage("your-space-personal-agent-provider") private var personalAgentProviderRawValue: String = ""
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
    /// Private, device-local markers left under group messages handed to an
    /// agent. They are deliberately not reactions broadcast to the group.
    @State private var messageAgentReceiptStore: MessageAgentReceiptStore = .init()
    /// The source message for the destination-only agent picker opened from a
    /// group message's long-press menu.
    @State private var messageToSendToAgent: AnyMessage?
    /// An agent response waiting for a destination Convo. The sheet owns only
    /// selection; the group composer remains the confirmation boundary.
    @State private var agentShareDraft: AgentShareDraft?
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
    @State private var homeBrowserEntries: [HomeBrowserEntry] = []
    @State private var showingDebugInjector: Bool = false
    /// Consent surface for agent ability-use asks, managed by
    /// `prepareEscalationIfNeeded` keyed on `escalationTaskKey` (nil while
    /// the abilities flag is off or the conversation has no agent; rebuilt
    /// when the shown conversation changes).
    @State private var escalationViewModel: ConversationEscalationViewModel?
    @State private var presentingAddFromContactsPicker: Bool = false
    /// Presents the account Connections browser from the active agent DM composer.
    /// This branch predates the conversation-scoped browser mode on `dev`, so
    /// the existing catalog remains the compatible destination here.
    @State private var isConnectionsBrowserPresented: Bool = false
    /// Drives the system share sheet behind the top bar's invite-link button.
    @State private var presentingInviteShareSheet: Bool = false
    @State private var navState: ConversationNavigatorImpl = .init()
    @State private var navigator: ConversationCollector?

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
        let content = MessagesView(
            contextMenuState: contextMenuState,
            messageAgentReceiptStore: messageAgentReceiptStore,
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
            // Clearance for the top chrome the transcript scrolls under.
            topContentInset: ConversationChromeMetrics.controlClearance,
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
        .task(id: escalationTaskKey) { prepareEscalationIfNeeded() }
        .task(id: viewModel.conversation.id) {
            agentChatPrototypeState.bind(to: viewModel.conversation.id)
        }
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

        return privacyPrompts(for: content)
    }

    private func privacyPrompts<Content: View>(for content: Content) -> some View {
        content
        .confirmationDialog(
            "Pause agents?",
            isPresented: $showingPausePrivacyPrompt,
            titleVisibility: .visible
        ) {
            Button("Pause + turn on disappearing messages") {
                pauseAgents(enableDisappearingMessages: true)
            }
            Button("Pause only") {
                pauseAgents(enableDisappearingMessages: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paused agents won’t see new messages. You can also make new messages disappear after your selected timer, or after 24 hours if you haven’t chosen one.")
        }
        .alert("Couldn't update disappearing messages", isPresented: Binding(
            get: { disappearingMessagesError != nil },
            set: { if !$0 { disappearingMessagesError = nil } }
        )) {
            Button("OK", role: .cancel) { disappearingMessagesError = nil }
        } message: {
            Text(disappearingMessagesError ?? "Please try again.")
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
        let agentDmRequested: Bool = initialAgentDmInboxId != nil
            && agentChatLanes.contains { $0.liveInboxId == initialAgentDmInboxId }
        let tab: ConversationTab = ConversationTab.initial(
            available: availableTabs,
            agentDmRequested: agentDmRequested
        )
        guard tab != selectedTab else { return }
        selectTab(tab)
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
        if let agentInboxId = note.userInfo?["agentInboxId"] as? String,
           let requestedLane = agentChatLanes.first(where: { $0.liveInboxId == agentInboxId }) {
            agentChatPrototypeState.select(requestedLane)
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

    /// Agent switching and Ghost Mode stay non-production until the server
    /// contracts in `agent-chat-server-contract.md` are implemented. PR and
    /// Dev builds get the complete clickable prototype.
    private var showsAgentChatPrototype: Bool {
        !ConfigManager.shared.currentEnvironment.isProduction
    }

    private var liveAgentChatLanes: [AgentChatLane] {
        guard !viewModel.conversation.isAgentDm else { return [] }
        return viewModel.conversation.members
            .filter(\.isVerifiedAgent)
            .map { member in
                AgentChatLane.live(
                    profile: member.profile,
                    verification: member.agentVerification
                )
            }
    }

    /// The group-local Convos agent is always first: its verified XMTP lane
    /// when available, or the orange preview while that member is syncing.
    /// Personal agents the user connected follow it. The old Flight Tracker
    /// and Shane's Agent sample lanes intentionally do not enter the selector.
    private var agentChatLanes: [AgentChatLane] {
        guard showsAgentChatPrototype else { return liveAgentChatLanes }
        return AgentChatLane.available(
            live: liveAgentChatLanes,
            connectedExternalProviders: personalAgentProvidersForSelector,
            grokBotAgents: GrokBotConnectionStore.configuration()?.enabledAgents ?? []
        )
    }

    private var personalAgentProvidersForSelector: [ExternalAgentProvider] {
        var providers = agentChatPrototypeState.connectedExternalProviders
        for provider in AddedExternalAgentStore.providers(session: viewModel.session)
            where !providers.contains(provider) {
            providers.append(provider)
        }
        if let remembered = ExternalAgentProvider(rawValue: personalAgentProviderRawValue),
           remembered.connectionAvailability == .live,
           !providers.contains(remembered) {
            providers.append(remembered)
        }
        return providers.sorted { lhs, rhs in
            (ExternalAgentProvider.allCases.firstIndex(of: lhs) ?? .max)
                < (ExternalAgentProvider.allCases.firstIndex(of: rhs) ?? .max)
        }
    }

    private var selectedAgentChatLane: AgentChatLane? {
        if let selectedLaneId = agentChatPrototypeState.selectedLaneId,
           let selected = agentChatLanes.first(where: { $0.id == selectedLaneId }) {
            return selected
        }
        if let initialAgentDmInboxId,
           let requested = agentChatLanes.first(where: { $0.liveInboxId == initialAgentDmInboxId }) {
            return requested
        }
        if let primaryAgentInboxId,
           let primary = agentChatLanes.first(where: { $0.liveInboxId == primaryAgentInboxId }) {
            return primary
        }
        return agentChatLanes.first
    }

    private var activeAgentInboxId: String? {
        guard showsAgentChatPrototype else { return primaryAgentInboxId }
        return selectedAgentChatLane?.liveInboxId
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
            agentInboxId: activeAgentInboxId
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

    private var activeContextMenuState: MessageContextMenuState {
        selectedTab == .agent ? agentContextMenuState : contextMenuState
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

    /// The Agent tab is a dark surface, and its composer's materials resolve
    /// against the UIKit trait collection rather than SwiftUI's environment,
    /// so the scheme has to be forced rather than set in the environment.
    ///
    /// Applied to the pages and the top chrome, not to the whole screen: the
    /// conversation's title capsule is drawn by `ConversationPresenter` above
    /// this view and belongs to the conversation, not to the selected tab.
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
        // Keeps the Agent tab bound to the selected live agent, and
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
            session.setAgent(inboxId: activeAgentInboxId)
            await session.rebindWhenDmAppears()
        }
    }

    var body: some View {
        conversationPresentations(conversationCore)
        .confirmationDialog(
            messageDeleteConfirmationTitle,
            isPresented: $showingMessageDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if activeContextMenuState.canDeleteSelectionForEveryone {
                Button("Delete for everyone", role: .destructive) {
                    deleteSelectedMessages(forEveryone: true)
                }
            }
            Button("Delete for me", role: .destructive) {
                deleteSelectedMessages(forEveryone: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(messageDeleteConfirmationMessage)
        }
        .alert("Couldn't delete messages", isPresented: Binding(
            get: { messageDeletionError != nil },
            set: { if !$0 { messageDeletionError = nil } }
        )) {
            Button("OK", role: .cancel) { messageDeletionError = nil }
        } message: {
            Text(messageDeletionError ?? "Please try again.")
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
            updateGroupOnScreen(isOnScreen: true)
            captureAmbientScheme(presentedColorScheme)
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
        .onDisappear {
            viewModel.onConversationDisappeared()
            contextMenuState.cancelMessageSelection()
            agentContextMenuState.cancelMessageSelection()
            updateGroupOnScreen(isOnScreen: false)
            // The DM clears its own registration when its page unmounts, which
            // only happens if the Agent tab was ever visited. Clearing from here
            // too covers the conversation that binds a DM and never shows it.
            agentDmSession?.updateDmOnScreen(isOnScreen: false)
            navigator?.closed(context: navState.closeContext())
            escalationViewModel?.stopObserving()
        }
        // Keep the edge-swipe back gesture, drop the content-area one while
        // this screen is up (see ContentPopGestureDisabler).
        .background {
            ContentPopGestureDisabler()
                .frame(width: 0, height: 0)
        }
        // While Context browser pages are showing, the pop-a-page back button
        // in `topBarTrailing` stands in for the system one.
        .navigationBarBackButtonHidden(isBrowsingHome)
        .modifier(HomeBrowsingReporter(isBrowsing: isBrowsingHome, onChanged: onHomeBrowsingChanged))
        .modifier(metricsObserversPart1)
        .modifier(metricsObserversPart2)
        .modifier(metricsObserversPart3)
        .onChange(of: presentedColorScheme) { _, scheme in
            captureAmbientScheme(scheme)
        }
        .toolbar { topBarTrailing }
        .onDisappear {
            VoiceMemoPlayer.shared.stop()
            viewModel.voiceMemoRecorder.cancelRecording()
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
        messagePresentations(conversationLevelPresentations(connectionsBrowserPresentation(content)))
    }

    @ViewBuilder
    func connectionsBrowserPresentation(_ content: some View) -> some View {
        content
            .fullScreenCover(isPresented: $isConnectionsBrowserPresented) {
                NavigationStack {
                    AbilitiesListScreen(selection: AbilitiesServices.selection)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") {
                                    isConnectionsBrowserPresented = false
                                }
                            }
                        }
                }
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
                ProfileSetupSheet(mode: .edit, session: viewModel.session)
            }
            .sheet(item: $messageToSendToAgent) { message in
                AgentMessageDestinationSheet(
                    lanes: agentChatLanes,
                    prototypeState: agentChatPrototypeState,
                    session: viewModel.session,
                    onSelect: { lane in
                        openGroupMessage(message, in: lane)
                    }
                )
                .preferredColorScheme(.dark)
                .presentationBackground(.colorBackgroundSurfaceless)
            }
            .sheet(item: $agentShareDraft) { draft in
                AgentShareToConvoSheet(
                    conversations: draft.conversations,
                    currentConversationId: viewModel.conversation.id,
                    onSelect: { conversation in
                        stageAgentResult(draft.text, in: conversation)
                    }
                )
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
            .selfSizingSheet(item: presentedAgentReceiptBinding) { receipt in
                AgentReceiptDrawer(
                    receipt: receipt,
                    lane: agentChatLanes.first(where: { $0.id == receipt.agentId })
                )
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
        contextMenuState.cancelMessageSelection()
        agentContextMenuState.cancelMessageSelection()
        transferKeyboard(to: newTab)
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
        }
        updateReadingLane(from: oldTab, to: newTab)
    }

    private func handleAgentLaneSelection(_ lane: AgentChatLane) {
        agentContextMenuState.cancelInFlightSwipe()
        agentChatPrototypeState.select(lane)
    }

    private var presentedAgentReceiptBinding: Binding<MessageAgentReceipt?> {
        Binding(
            get: { messageAgentReceiptStore.presentedReceipt },
            set: { receipt in
                if let receipt {
                    messageAgentReceiptStore.present(receipt)
                } else {
                    messageAgentReceiptStore.dismissPresentedReceipt()
                }
            }
        )
    }

    /// Opens the selected private agent lane with an editable draft. Selection
    /// itself never dispatches the message; the destination composer remains
    /// the confirmation boundary.
    private func openGroupMessage(_ message: AnyMessage, in lane: AgentChatLane) {
        guard let text = agentHandoffText(for: message) else { return }
        let receipt = lane.receipt(
            conversationId: viewModel.conversation.id,
            messageId: message.messageId
        )
        withAnimation(.snappy(duration: 0.24)) {
            messageAgentReceiptStore.upsert(receipt)
        }

        if let liveInboxId = lane.liveInboxId {
            let session = agentDmSession ?? AgentDmSession(originViewModel: viewModel)
            if agentDmSession == nil { agentDmSession = session }
            session.stageDraft(text, to: liveInboxId)
        } else {
            agentChatPrototypeState.stageDraft(text, in: lane)
        }

        selectTab(.agent)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            agentFocusCoordinator.moveFocus(to: .message)
        }
    }

    private func prepareAgentResultForSharing(_ text: String) {
        var conversations = ((try? viewModel.session
            .conversationsRepository(for: [.allowed, .unknown])
            .fetchAll()) ?? [])
            .filter { !$0.isAgentDm }
        if !conversations.contains(where: { $0.id == viewModel.conversation.id }) {
            conversations.append(viewModel.conversation)
        }
        let destinations = onStageTextInConversation == nil
            ? conversations.filter { $0.id == viewModel.conversation.id }
            : conversations
        agentShareDraft = AgentShareDraft(text: text, conversations: destinations)
    }

    private func stageAgentResult(_ text: String, in conversation: Conversation) {
        if conversation.id != viewModel.conversation.id {
            onStageTextInConversation?(text, conversation)
            return
        }
        viewModel.messageText = mergingComposerDraft(viewModel.messageText, with: text)
        selectTab(.group)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            focusCoordinator.moveFocus(to: .message)
        }
    }

    private func mergingComposerDraft(_ current: String, with addition: String) -> String {
        let existing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }
        return "\(existing)\n\n\(incoming)"
    }

    /// The selected row is the complete privacy boundary: no surrounding
    /// transcript or hidden Home context is silently attached to the handoff.
    private func agentHandoffText(for message: AnyMessage) -> String? {
        let body: String = switch message.content {
        case .text(let text), .emoji(let text):
            text
        case .invite(let invite):
            "Convo invite: https://\(ConfigManager.shared.associatedDomain)/v2?i=\(invite.inviteSlug)"
        case .agentShare(let share):
            share.url
        case .attachment(let attachment):
            attachment.filename ?? attachment.mediaType.previewLabel
        case .attachments(let attachments):
            attachments.map { $0.filename ?? $0.mediaType.previewLabel }.joined(separator: ", ")
        case .update(let update):
            update.summary
        case .linkPreview(let preview):
            preview.url
        case .assistantJoinRequest:
            "Agent join request"
        case .connectionGrantRequest(let request):
            "\(request.service) connection request: \(request.reason)"
        case .capabilityConnect(let prompt):
            "\(prompt.serviceName) connection request"
        case .connectionEvent(let summary),
             .connectionInvocation(let summary),
             .connectionInvocationResult(let summary),
             .connectionPayload(let summary):
            summary.text
        }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return nil }
        let senderName = message.sender.isCurrentUser ? "You" : message.sender.profile.displayName
        return "\(senderName) shared in this Convo:\n\(trimmedBody)"
    }

    private func updateReadingLane(from oldTab: ConversationTab, to newTab: ConversationTab) {
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

    /// The conversation is leaving the foreground, so nobody is reading it.
    ///
    /// Hands back the selected lane's claim on being read, which is what makes a
    /// message arriving now mark its lane unread and badge its tab - the claim
    /// exists precisely to suppress that. Read receipts stop for the same reason:
    /// the user is not looking at the transcript.
    ///
    /// Deliberately marks nothing read. What arrives while the conversation is
    /// away is unread, and staying unread is the whole point.
    private func releaseReadingLane() {
        // Both lanes, not just the selected one: an in-flight read mark from
        // either would clear an unread that arrives after leaving.
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
        if !topBarTrailingHidden && !isBrowsingHome && !activeContextMenuState.isSelectingMessages {
            ToolbarItem(placement: .topBarTrailing) {
                surfaceTrailingAction
            }
        }
    }

    /// The shared top-right group action. The Agent tab omits it entirely.
    @ViewBuilder
    private var surfaceTrailingAction: some View {
        if !topBarTrailingHidden {
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
                case .scan:
                    scanInviteButton
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

    /// Opens the exact verified group agent this person invited. The callback
    /// belongs to the profiled human, while its argument is the attributed
    /// agent inbox; keeping those identities separate preserves the action for
    /// agents that do not carry a reusable template id.
    private func startAgentDmAction(for member: ConversationMember) -> ((String) -> Void)? {
        guard let groupAgent = viewModel.conversation.groupAgentSetUp(by: member.profile.inboxId) else {
            return nil
        }
        return { agentInboxId in
            guard agentInboxId == groupAgent.profile.inboxId else { return }
            viewModel.presentingProfileForMember = nil
            NotificationCenter.default.post(
                name: .selectAgentDmPageRequested,
                object: nil,
                userInfo: [
                    "conversationId": viewModel.conversation.id,
                    "agentInboxId": agentInboxId,
                ]
            )
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
        AnyView(
            MemberContactDetailSheetContent(
                viewModel: viewModel,
                member: member,
                profileSettingsViewModel: profileSettingsViewModel,
                onStartAgentDm: startAgentDmAction(for: member)
            )
        )
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
            ConversationTopChrome(topSafeAreaInset: windowSafeAreaInsets.top) {
                if activeContextMenuState.isSelectingMessages {
                    messageSelectionHeader
                } else {
                    ConversationSegmentedControl(
                        selectedTab: $selectedTab,
                        tabs: availableTabs,
                        badgedTabs: badgedTabs
                    )
                }
            }
        }
        .overlay { messageContextMenuOverlay }
        .overlay(alignment: .bottom) { messageSelectionBottomBar }
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
        // Scoped here rather than to `body`: the Agent tab's dark surface is the
        // page's, and the conversation's title capsule above this view keeps the
        // conversation's own scheme.
        .preferredColorScheme(preferredScheme)
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
        ZStack {
            groupPage
            agentPage
            contextPage
        }
    }

    private var groupPage: some View {
        let isActive: Bool = selectedTab == .group
        return messagesView(focus: $focusState)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
    }

    @ViewBuilder
    private var agentPage: some View {
        if visitedTabs.contains(.agent), let agentDmSession {
            let isActive: Bool = selectedTab == .agent
            AgentDmPageView(
                session: agentDmSession,
                profileSettingsViewModel: profileSettingsViewModel,
                extraBottomInset: 0,
                connectionsEnabled: composerConnectionsEnabled,
                onConnectionsTap: handleComposerConnectionsTap,
                isReadOnly: effectiveReadOnly,
                isActiveTab: isActive,
                contextMenuState: agentContextMenuState,
                focusState: $agentFocus,
                focusCoordinator: agentFocusCoordinator,
                onScrollToBottomAvailable: { scrollFn in
                    // Same deferral as the group transcript's bridge.
                    DispatchQueue.main.async {
                        agentScrollToBottom = scrollFn
                    }
                },
                prototypeState: showsAgentChatPrototype ? agentChatPrototypeState : nil,
                selectedLane: showsAgentChatPrototype ? selectedAgentChatLane : nil,
                lanes: showsAgentChatPrototype ? agentChatLanes : [],
                onSelectLane: handleAgentLaneSelection(_:),
                onShareToConvo: prepareAgentResultForSharing(_:)
            )
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
        }
    }

    /// The Context tab: the conversation's Space page, in a navigation stack of
    /// its own so a link tapped inside it pushes without leaving the
    /// conversation. The stack wraps this page only - the chrome is a sibling
    /// above it, so pushing a page never slides the segmented control away.
    @ViewBuilder
    private var contextPage: some View {
        if visitedTabs.contains(.context) {
            let isActive: Bool = selectedTab == .context
            HomeBrowserNavigationHost(
                entries: $homeBrowserEntries,
                root: { AnyView(spaceSurface) },
                page: { entry in AnyView(homeBrowserPage(for: entry)) }
            )
            .ignoresSafeArea()
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
        }
    }

    /// One page in the Context tab's browsing chain.
    @ViewBuilder
    func homeBrowserPage(for entry: HomeBrowserEntry) -> some View {
        HomeBrowserPageView(
            entry: entry,
            onNavigationRequest: { url in
                pushHomeBrowserPage(for: url)
            }
        )
    }

    /// The Context tab's root: the conversation's Space web surface.
    var spaceSurface: some View {
        HomeLayoutView(
            webURL: viewModel.conversation.spaceURL,
            onNavigationRequest: { url in
                pushHomeBrowserPage(for: url)
            }
        )
    }

    /// The single host seam for the composer's connections capability: the
    /// `+` menu row and the browser modal both feed from this one read. No
    /// composer surface consults the flag directly.
    var composerConnectionsEnabled: Bool {
        FeatureFlags.shared.isAbilitiesV2Enabled
    }

    /// Powerplug tap from the `+` menu row: presents the Connections
    /// browser full-screen, carrying the launching DM's conversation,
    /// agent inbox id and agent name so its Connected section can scope
    /// its toggles. Guarded by the same capability that offered the row.
    func handleComposerConnectionsTap() {
        guard composerConnectionsEnabled,
              agentDmSession?.agentInboxId != nil,
              agentDmSession?.dmViewModel?.conversation.id != nil else {
            return
        }
        isConnectionsBrowserPresented = true
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
            onSendToAgent: selectedTab == .group && !agentChatLanes.isEmpty
                ? { message in messageToSendToAgent = message }
                : nil
        )
        .environment(\.agentShareResolver, lane.agentShareResolver)
        .environment(\.inviteMembershipResolver, lane.inviteMembershipResolver)
    }

    var messageSelectionHeader: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Text("\(activeContextMenuState.selectedMessages.count) selected")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Spacer()
            Button {
                activeContextMenuState.cancelMessageSelection()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(isDeletingSelectedMessages)
            .accessibilityLabel("Cancel message selection")
        }
        .padding(.leading, DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    var messageSelectionBottomBar: some View {
        if activeContextMenuState.isSelectingMessages {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text("\(activeContextMenuState.selectedMessages.count) selected")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.colorTextSecondary)
                    Spacer()
                    Button(role: .destructive) {
                        showingMessageDeleteConfirmation = true
                    } label: {
                        Group {
                            if isDeletingSelectedMessages {
                                ProgressView()
                            } else {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                        }
                        .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.colorCaution)
                    .disabled(isDeletingSelectedMessages)
                    .accessibilityLabel("Delete selected messages")
                }
                .padding(.horizontal, DesignConstants.Spacing.step5x)
                .padding(.top, DesignConstants.Spacing.step3x)
                .padding(.bottom, max(windowSafeAreaInsets.bottom, DesignConstants.Spacing.step3x))
            }
            .background(.ultraThinMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(200)
        }
    }

    var messageDeleteConfirmationTitle: String {
        let count = activeContextMenuState.selectedMessages.count
        return count == 1 ? "Delete message?" : "Delete \(count) messages?"
    }

    var messageDeleteConfirmationMessage: String {
        guard activeContextMenuState.canDeleteSelectionForEveryone else {
            return "This removes the selected messages from this device only."
        }
        let hasAgent = activeLaneViewModel.conversation.members.contains(where: \.isAgent)
        if hasAgent {
            return "This removes the selected messages for people using message deletion. Agents may still keep copies outside Convos."
        }
        return "This removes the selected messages for people using message deletion."
    }

    func deleteSelectedMessages(forEveryone: Bool) {
        let state = activeContextMenuState
        let messages = state.selectedMessages
        let lane = activeLaneViewModel
        guard !messages.isEmpty else { return }

        isDeletingSelectedMessages = true
        Task {
            do {
                if forEveryone {
                    try await lane.deleteMessagesForEveryone(messages)
                } else {
                    try await lane.deleteMessagesForMe(messages)
                }
                state.cancelMessageSelection()
            } catch {
                Log.error("Failed deleting selected messages: \(error.localizedDescription)")
                state.cancelMessageSelection()
                messageDeletionError = "Some messages may not have been deleted. Please try again."
            }
            isDeletingSelectedMessages = false
        }
    }

    /// Extra rows above the group composer: the injected bottom-bar slot plus
    /// the status slot. The transcript owns its composer, so this pair renders
    /// in the composer's content slot.
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
    var showsCloseButton: Bool = true
    var embedsNavigationStack: Bool = true
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var sessionResolvedMode: ContactDetailMode?

    @ViewBuilder
    var body: some View {
        if embedsNavigationStack {
            NavigationStack { resolvedContent }
        } else {
            resolvedContent
        }
    }

    @ViewBuilder
    private var resolvedContent: some View {
        if let presentationMode {
            contactDetail(mode: presentationMode)
        } else {
            ProgressView("Opening profile…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.colorBackgroundRaisedSecondary)
                .task(id: member.profile.inboxId) { await resolvePresentationMode() }
        }
    }

    private var baseMode: ContactDetailMode {
        .scopedToConversation(
            conversationId: viewModel.conversation.id,
            canRemoveMembers: viewModel.canRemoveMembers,
            isCurrentUser: member.isCurrentUser,
            invitedBy: member.invitedBy,
            joinedAt: member.joinedAt
        )
    }

    private var presentationMode: ContactDetailMode? {
        member.isCurrentUser ? baseMode : sessionResolvedMode
    }

    @MainActor
    private func resolvePresentationMode() async {
        sessionResolvedMode = await baseMode.resolvingCurrentUser(
            contactInboxId: member.profile.inboxId,
            session: viewModel.session,
            conversationId: viewModel.conversation.id
        )
    }

    private func contactDetail(mode: ContactDetailMode) -> some View {
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
        return ContactDetailView(
            contact: resolvedContact,
            variantStamp: member.profile.variant,
            connectedAgentProviderIds: member.profile.connectedAgentProviderIds,
            groupAgentSetUpByContact: viewModel.conversation.groupAgentSetUp(
                by: member.profile.inboxId
            ),
            mode: mode,
            contactsWriter: contactsWriter,
            contactsRepository: contactsRepository,
            session: viewModel.session,
            coreActions: viewModel.coreActions,
            profileSettingsViewModel: profileSettingsViewModel,
            showsCloseButton: showsCloseButton,
            onRemove: onRemove,
            onStartAgentDm: onStartAgentDm
        )
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
            selectParticipationLevel(level)
        }
    }

    func selectParticipationLevel(_ level: AgentParticipationLevel) {
        guard level == .paused,
              !viewModel.conversation.isDisappearingMessagesEnabled else {
            Task { await participation?.set(level) }
            return
        }

        let conversationId = viewModel.conversation.id
        if DisappearingMessagesPreferences.automaticallyEnableWhenAgentsPause(conversationId: conversationId) {
            pauseAgents(enableDisappearingMessages: true)
        } else {
            showingPausePrivacyPrompt = true
        }
    }

    func pauseAgents(enableDisappearingMessages: Bool) {
        Task {
            await participation?.set(.paused)
            guard enableDisappearingMessages, participation?.level == .paused else { return }

            let conversationId = viewModel.conversation.id
            let duration = DisappearingMessagesPreferences.durationWhenAgentsPause(conversationId: conversationId)
            do {
                try await viewModel.updateDisappearingMessages(duration)
                DisappearingMessagesPreferences.remember(duration, conversationId: conversationId)
            } catch {
                Log.error("Failed to enable disappearing messages after pausing agents in \(conversationId): \(error)")
                disappearingMessagesError = "Please try again."
            }
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
