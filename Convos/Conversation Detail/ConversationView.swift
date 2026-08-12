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
    /// Tabs the user has visited. The Desktop web view and the agent DM
    /// mount on first visit and stay mounted (hidden, not torn down) so tab
    /// switches never reload them.
    @State private var visitedTabs: Set<ConversationTab> = [.group]
    /// Guards the one-time seed of `selectedTab` from `initialAgentDmInboxId`.
    @State private var didSeedInitialTab: Bool = false
    /// The sheet's detent. Only `.compact` is reachable today; see
    /// `ConversationSheetDetent`.
    @State private var sheetDetent: ConversationSheetDetent = .compact
    /// The sheet's live measured bottom clearance from the physical screen
    /// edge, fed to every backing view so transcripts and scroll content
    /// clear the resting card.
    @State private var sheetOccupiedHeight: CGFloat = ConversationSheetMetrics.compactRestingHeight
    /// Window safe-area insets, used to convert the sheet's physical-edge
    /// clearance into the safe-area-relative inset the transcripts take.
    @Environment(\.safeAreaInsets) private var windowSafeAreaInsets: EdgeInsets
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
    /// The desktop browser popup stack: each intercepted navigation pushes a
    /// fresh entry above the desktop surface and below the sheet.
    @State private var desktopBrowserEntries: [DesktopBrowserEntry] = []
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
            extraBottomInset: transcriptBottomInset,
            showsInviteScanCard: showsTopOfConvoInvite,
            inviteScanMode: inviteScanMode,
            inviteScanInitialSegment: embeddedInviteInitialSegment,
            onScannedInviteCode: inviteScanScannedHandler,
            onInviteShareCompleted: onInviteShareCompletedHandler,
            // The composer lives in the conversation sheet now (see
            // `sheetBarContent`); the transcript insets by the sheet's
            // measured height instead of hosting a bar.
            hostsBottomBar: false,
            onScrollToBottomAvailable: { scrollFn in
                groupScrollToBottom = scrollFn
            },
            bottomBarContent: { EmptyView() }
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

    /// Opens the Agent tab once, when the view was pushed from a
    /// conversations-list row whose most-recent unread is in the DM.
    private func seedInitialTabIfNeeded() {
        guard !didSeedInitialTab else { return }
        didSeedInitialTab = true
        guard let inboxId = initialAgentDmInboxId,
              inboxId == primaryAgentInboxId else {
            return
        }
        selectTab(.agent)
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

    /// The sheet's clearance above the *safe-area* bottom line, which is
    /// what the transcripts inset by (their controllers add the safe area
    /// and keyboard themselves). The card extends into the bottom safe
    /// area like the native tab bar, so that region is subtracted while
    /// the keyboard is down; with the keyboard up the card rests directly
    /// above it and the full measured clearance applies.
    private var transcriptBottomInset: CGFloat {
        isKeyboardVisible
            ? sheetOccupiedHeight
            : max(sheetOccupiedHeight - windowSafeAreaInsets.bottom, 0)
    }

    var body: some View {
        conversationLayout
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            visitedTabs.insert(newTab)
            let keyboardWasUp: Bool = isKeyboardVisible
            if newTab == .group {
                // Returning to the group: transfer the keyboard back onto the
                // group composer when the user switched in mid-edit.
                if keyboardWasUp {
                    focusCoordinator.moveFocus(to: .message)
                }
            } else if oldTab == .group {
                // Leaving the group for a peer tab: release the group
                // composer. The agent page re-grabs focus onto its own
                // composer (transferring the keyboard); the Desktop tab has
                // no composer, so it drops.
                focusCoordinator.dismissMessageComposerIfNeeded()
                // A right-swipe can both start a reply and switch away;
                // cancel the in-flight reply swipe so the tab change doesn't
                // fire a reply.
                contextMenuState.cancelInFlightSwipe()
            }
        }
        // Keeps the Agent tab bound to the conversation's current agent, and
        // keeps retrying the DM bind until the agent-created DM syncs in.
        .task(id: primaryAgentInboxId) {
            let session = agentDmSession ?? AgentDmSession(originViewModel: viewModel)
            if agentDmSession == nil {
                agentDmSession = session
            }
            session.setAgent(inboxId: primaryAgentInboxId)
            await session.rebindWhenDmAppears()
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
            seedInitialTabIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAgentDmPageRequested)) { note in
            handleSelectAgentDmPageRequest(note)
        }
        .onDisappear {
            viewModel.onConversationDisappeared()
            navigator?.closed(context: navState.closeContext())
        }
        // Keep the edge-swipe back gesture, drop the content-area one while
        // this screen is up (see ContentPopGestureDisabler).
        .background {
            ContentPopGestureDisabler()
                .frame(width: 0, height: 0)
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

// MARK: - Layout

private extension ConversationView {
    /// The conversation's layered layout: the selected tab's backing view
    /// filling the screen, the desktop browser popups above it, and the
    /// floating conversation sheet over everything. The sheet is a
    /// bottom-aligned ZStack sibling (not an overlay - safe-area expansion
    /// doesn't reach overlay children), so it can extend into the bottom
    /// safe area like the native tab bar while still riding the keyboard.
    var conversationLayout: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                backingViews
                desktopBrowserPopups
            }
            conversationSheet
        }
    }

    /// One backing view per tab, all kept mounted once visited: switching
    /// flips opacity and hit-testing instead of tearing views down, so the
    /// UIKit transcripts keep their scroll state and the desktop web view
    /// never reloads on a tab hop.
    var backingViews: some View {
        ZStack {
            messagesView
                .opacity(selectedTab == .group ? 1 : 0)
                .allowsHitTesting(selectedTab == .group)
            if visitedTabs.contains(.agent), let agentDmSession {
                AgentDmPageView(
                    session: agentDmSession,
                    extraBottomInset: transcriptBottomInset,
                    isReadOnly: effectiveReadOnly,
                    isActiveTab: selectedTab == .agent,
                    keyboardVisible: isKeyboardVisible,
                    contextMenuState: agentContextMenuState,
                    focusState: $agentFocusState,
                    focusCoordinator: agentFocusCoordinator,
                    onScrollToBottomAvailable: { scrollFn in
                        agentScrollToBottom = scrollFn
                    }
                )
                .opacity(selectedTab == .agent ? 1 : 0)
                .allowsHitTesting(selectedTab == .agent)
            }
            if visitedTabs.contains(.desktop) {
                DesktopLayoutView(
                    conversationId: viewModel.conversation.id,
                    webURL: viewModel.conversation.spaceURL,
                    sheetHeight: sheetOccupiedHeight,
                    onNavigationRequest: { url in
                        desktopBrowserEntries.append(DesktopBrowserEntry(url: url))
                    }
                )
                .opacity(selectedTab == .desktop ? 1 : 0)
                .allowsHitTesting(selectedTab == .desktop)
            }
        }
    }

    /// The stacked desktop browser popups: each intercepted navigation
    /// pushes a fresh entry whose page pins its own URL; further navigation
    /// stacks another popup on top.
    @ViewBuilder
    var desktopBrowserPopups: some View {
        ForEach(desktopBrowserEntries) { entry in
            DesktopBrowserPopup(
                url: entry.url,
                onNavigationRequest: { url in
                    desktopBrowserEntries.append(DesktopBrowserEntry(url: url))
                },
                onClose: {
                    desktopBrowserEntries.removeAll { $0.id == entry.id }
                }
            )
            .ignoresSafeArea()
        }
    }

    var conversationSheet: some View {
        ConversationBottomSheet(
            detent: $sheetDetent,
            isHidden: contextMenuState.isPresented || agentContextMenuState.isPresented,
            onOccupiedHeightChanged: { height in
                sheetOccupiedHeight = height
            },
            barContent: { sheetBarContent },
            tabBar: { ConversationTabBar(selectedTab: $selectedTab) }
        )
        // Like the native floating tab bar, the card rests inside the bottom
        // safe area: its edge inset is measured from the physical screen
        // edge. Positioned by explicit compensation rather than
        // `.ignoresSafeArea` - the presenter/tab-shell chain above neutralizes
        // safe-area expansion for this subtree - and dropped while the
        // keyboard is up, when the card rests directly above it instead.
        .padding(.bottom, isKeyboardVisible ? 0 : -windowSafeAreaInsets.bottom)
    }

    /// The bar the sheet hosts above its tab bar, keyed by the selected tab:
    /// the group composer, the agent-DM composer (disabled until the DM
    /// exists), or nothing on the Desktop tab.
    @ViewBuilder
    var sheetBarContent: some View {
        switch selectedTab {
        case .desktop:
            EmptyView()
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

    /// Extra rows above the group composer: the injected bottom-bar slot
    /// (e.g. the Agent Builder's chrome) plus the capability-approved toast /
    /// onboarding pair. Capability requests no longer auto-present a card
    /// here: the transcript's connect pill is the single entry point and
    /// opens the approval sheet.
    var groupExtraBarContent: some View {
        @Bindable var onboardingCoordinator = viewModel.onboardingCoordinator
        return VStack(spacing: DesignConstants.Spacing.step3x) {
            bottomBarContent()

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
