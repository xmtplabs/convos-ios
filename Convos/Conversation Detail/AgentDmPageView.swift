import ConvosComposer
import ConvosCore
import SwiftUI
import UIKit

/// The Agent tab's backing view: the user's private DM with the
/// conversation's agent, rendered behind the conversation sheet. The DM is a
/// real 2-member conversation (see docs/plans/agent-dms.md).
///
/// The DM's lifecycle lives in `AgentDmSession`, owned by `ConversationView`:
/// once the DM exists this view renders the same `MessagesView` the group chat
/// uses, composer included, so list layout, filtering, and interactions behave
/// identically. Before the agent-created DM syncs in it shows the disclosure
/// empty state while the composer sits
/// disabled.
struct AgentDmPageView: View {
    let session: AgentDmSession
    /// Backs the contact card opened from an avatar tap, the same way the
    /// group transcript's does.
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    /// Clearance for the conversation sheet floating over the transcript.
    /// Owned by ConversationView, which keeps it fed with the sheet's
    /// measured height.
    let extraBottomInset: CGFloat
    var topContentInset: CGFloat = ConversationChromeMetrics.contentClearance
    /// Host gate for the composer `+` menu's Connections row.
    var connectionsEnabled: Bool = false
    /// Presents the host's Connections browser, scoped to this DM.
    var onConnectionsTap: (() -> Void)?
    /// Mirrors ConversationView's effectiveReadOnly: a removed or stale
    /// device must not be able to send into agent DMs.
    let isReadOnly: Bool
    /// True when the conversation's agent participation is paused. The DM's send
    /// button then shows the paused visual, sends are blocked, and the composer
    /// hint changes; a blocked attempt raises the paused alert.
    var sendButtonPaused: Bool = false
    /// Resumes the agent (participation -> speak freely) from the paused alert's
    /// Unpause action. Owned by ConversationView, which holds the participation
    /// store the DM page can't reach.
    var onUnpauseAgent: () -> Void = {}
    /// True while the Agent tab is the selected tab. The backing views stay
    /// mounted across tab switches, so activation drives the read state and
    /// the active-DM push lane. (Composer focus transfers are owned by
    /// ConversationView's tab-change handler, through the focus
    /// coordinators.)
    let isActiveTab: Bool
    /// Owned by ConversationView, which renders the DM's long-press context
    /// menu at its own root.
    @Bindable var contextMenuState: MessageContextMenuState
    /// Focus shared with the agent composer; deliberately not the group
    /// composer's focus state, which stays mounted alongside this tab.
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    /// Offered every link tapped in this transcript before the in-app browser
    /// gets it. Carries the *group's* Space, not the DM's: the agent DMs you
    /// about pages it built for the group, and those belong in the same Home.
    var messageLinkRouter: MessageLinkRouter = { _ in false }
    /// The *group's* Space, for the same reason the router carries it.
    var conversationSpaceURL: URL?
    /// Bridges the DM transcript's scroll-to-bottom up to the sheet's
    /// composer, which fires it on send.
    var onScrollToBottomAvailable: ((@escaping (Bool) -> Void) -> Void)?
    /// Surfaces this transcript's content height, which caps how far the sheet
    /// opens on the Agent tab.
    var onContentHeightChanged: ((CGFloat) -> Void)?

    /// Fill of the preparing bar. Creeps while the agent is on its way; it
    /// tracks elapsed time, not real progress, since nothing reports any.
    @State private var preparingProgress: Double = Constant.progressStart

    private var agentName: String { session.agentName }

    @State private var emptyStateSettled: Bool = false
    @State private var showingPausedAgentAlert: Bool = false

    /// The stamp lives on the agent member's profile, written by the assistants
    /// worker at join. nil for a default agent, and nil off dev.
    private func agentVariant(in dmVm: ConversationViewModel) -> AgentVariantStamp? {
        dmVm.conversation.members.first(where: { $0.isAgent })?.profile.variant
    }

    var body: some View {
        Group {
            switch phase {
            case .ready(let dmViewModel):
                dmMessagesViewWithSheets(dmViewModel)
            case .preparing:
                preparingState
            case .noAgent:
                addAgentState
            }
        }
        .task {
            // Messages land just after the page appears; without this the
            // empty state would flash open and shut on a DM that has any.
            try? await Task.sleep(for: .milliseconds(300))
            emptyStateSettled = true
        }
        .environment(\.colorScheme, .dark)
        // A SwiftUI .alert takes its button color from the presenting
        // controller's tintColor, not the local `\.tint`, so on the agent tab -
        // forced dark by ScreenAppearanceScope, where the app's colorTextPrimary
        // tint resolves to white - the buttons read white on the light system
        // alert. Present a UIKit alert we control instead, pinned to a light
        // appearance so title, message, and buttons all read dark.
        .background {
            PausedAgentAlert(
                isPresented: $showingPausedAgentAlert,
                agentName: agentName,
                onUnpause: onUnpauseAgent
            )
        }
        // The agent-participation ("listen") control governs how much agents
        // speak in the group room; it has no meaning in a 1:1 agent DM, so clear
        // the inherited participation context to hide the control here.
        .environment(\.agentParticipation, nil)
        // The backing views mount on the tab's first visit with the tab
        // already active, so no isActiveTab change fires; handle the initial
        // activation (mark read, register the push-suppression lane) here.
        .onAppear {
            if isActiveTab {
                handleActiveTabChange(true)
            }
        }
        .onChange(of: isActiveTab) { _, active in
            handleActiveTabChange(active)
        }
        // Every conversation claimed from the warm cache already has a silent
        // default agent on the way. Ask whether this one does, so the tab
        // waits on that join instead of offering to add a second agent - and
        // ask again when the conversation settles into its real id, which is
        // the id that join was registered under.
        .task(id: provisioningRefreshKey) {
            await session.refreshDefaultAgentProvisioning()
        }
        // The DM can bind while this tab is already active (the reconciler
        // created it while the user waited here); the on-activate hook fired
        // before the view model existed, so mark it read and register the
        // lane now.
        .onChange(of: session.dmViewModel?.conversation.id) { _, dmId in
            guard dmId != nil, isActiveTab else { return }
            session.markDmAsRead()
            session.updateActiveDmLane(isActive: true)
        }
        // The backing views stay mounted, so this fires when the whole
        // conversation closes; clear the on-screen DM lane so its pushes are
        // no longer suppressed once the user has left.
        .onDisappear {
            if isActiveTab { session.updateActiveDmLane(isActive: false) }
            session.updateDmOnScreen(isOnScreen: false)
        }
    }

    /// Activation side effects: the read state and the push-suppression
    /// lane. Composer focus is not touched here - ConversationView's
    /// tab-change handler transfers it through the focus coordinators.
    private func handleActiveTabChange(_ active: Bool) {
        guard active else {
            // A right-swipe can both start a reply on a DM message and switch
            // tabs. When the tab changes, cancel the in-flight swipe and clear
            // any reply it already set, so a tab change never leaves the DM
            // stuck in reply mode.
            contextMenuState.cancelInFlightSwipe()
            session.dmViewModel?.replyingToMessage = nil
            // The user just had the DM on screen: anything that arrived
            // while they watched is read, so it doesn't badge the tab they
            // left.
            session.markDmAsRead()
            session.updateActiveDmLane(isActive: false)
            return
        }
        session.markDmAsRead()
        session.updateActiveDmLane(isActive: true)
    }

    // MARK: - Pre-creation

    /// What the tab has to show, in the order a conversation moves through
    /// it: no agent to talk to, an agent on its way, then the DM itself.
    private enum Phase {
        case noAgent
        case preparing
        case ready(ConversationViewModel)
    }

    /// Re-asks about provisioning when the conversation settles into its real
    /// id, when an agent binds, and when the tab is shown.
    private var provisioningRefreshKey: String {
        "\(session.originConversationId)-\(session.agentInboxId ?? "")-\(isActiveTab)"
    }

    private var phase: Phase {
        if let dmViewModel = session.dmViewModel {
            return .ready(dmViewModel)
        }
        // An agent that is already a member is only missing its DM, which the
        // agent creates moments later; a join still in flight is the same wait
        // one step earlier. Both read as "preparing".
        return session.hasNoAgent ? .noAgent : .preparing
    }

    /// Offered when the conversation has no agent at all (Figma 7488:14502).
    /// Centered in the band the reader can see, below the floating top chrome.
    private var addAgentState: some View {
        AddAgentPromptView(
            onAddAgent: session.requestAgentJoin,
            accessibilityIdentifier: "agent-dm-add-agent-button"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Inset past the floating top chrome so this centers in what the
        // reader can see rather than behind the segmented control. The
        // background sits outside the inset, so the dark surface still fills
        // the whole page.
        .padding(.top, topContentInset)
        .padding(.bottom, extraBottomInset)
        .background(.colorBackgroundSurfaceless)
    }

    /// Shown from the moment an agent is on its way until its DM lands. The
    /// bar carries no real progress - nothing reports any - so it creeps
    /// toward a cap and stops there, the way the old join card did.
    private var preparingState: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Text("Preparing your agent chat")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.colorLava)
            progressBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Inset past the floating top chrome so this centers in what the
        // reader can see rather than behind the segmented control. The
        // background sits outside the inset, so the dark surface still fills
        // the whole page.
        .padding(.top, topContentInset)
        .padding(.bottom, extraBottomInset)
        .background(.colorBackgroundSurfaceless)
        .task(id: isPreparing) {
            await rampPreparingProgress()
        }
        .accessibilityIdentifier("agent-dm-preparing")
    }

    private var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }

    /// Figma 7488:14256: a 120x8 track in 30% lava with a lava fill; the
    /// design's still frame shows it about a third full.
    private var progressBar: some View {
        let fillWidth: CGFloat = Constant.progressWidth * preparingProgress
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Constant.progressHeight)
                .fill(Color.colorLava.opacity(Constant.progressTrackOpacity))
                .frame(width: Constant.progressWidth, height: Constant.progressHeight)
            RoundedRectangle(cornerRadius: Constant.progressHeight)
                .fill(Color.colorLava)
                .frame(width: fillWidth, height: Constant.progressHeight)
        }
    }

    private func rampPreparingProgress() async {
        guard isPreparing else { return }
        while !Task.isCancelled, preparingProgress < Constant.progressCap {
            try? await Task.sleep(for: .seconds(Constant.progressTick))
            guard !Task.isCancelled else { return }
            let next: Double = min(preparingProgress + Constant.progressStep, Constant.progressCap)
            withAnimation(.easeOut(duration: Constant.progressTick)) {
                preparingProgress = next
            }
        }
    }

    /// The DM transcript: membership, invite, and agent-presence cells are
    /// origin-conversation concepts. A disclosure cell fills a settled empty
    /// transcript and disappears as soon as any filtered item arrives.
    private func dmItems(_ dmVm: ConversationViewModel) -> [MessagesListItemType] {
        let items = dmVm.messagesWithThinkingIndicators.compactMap { (item: MessagesListItemType) -> MessagesListItemType? in
            switch item {
            case .update, .agentPresentInfo, .conversationInfo, .agentJoinStatus:
                return nil
            case .messages(var group):
                // The processor pins the agent contact card to the agent's
                // first group (synthesizing an empty one when needed) - an
                // origin-conversation affordance the info cell replaces here.
                group.agentContactCard = nil
                guard !group.messages.isEmpty else { return nil }
                return .messages(group)
            default:
                return item
            }
        }
        guard emptyStateSettled, items.isEmpty else { return items }
        return [.agentDmInfo(agentName: agentName, variant: agentVariant(in: dmVm))]
    }

    // MARK: - Full chat (mirrors ConversationView.messagesView with the DM VM)

    private func contactOverride(for dmVm: ConversationViewModel) -> @Sendable (String) -> Contact? {
        Contact.memberAwareResolver(
            members: dmVm.conversation.members,
            contactLookup: dmVm.messagingService.contactsRepository().contact(for:)
        )
    }

    private func dmMessagesView(_ dmVm: ConversationViewModel) -> some View {
        @Bindable var dmVm = dmVm
        let messagePlaceholder: String = sendButtonPaused
            ? "\(agentName) is paused"
            : "Chat with \(agentName)"
        return MessagesView(
            contextMenuState: contextMenuState,
            conversation: dmVm.conversation,
            messages: dmItems(dmVm),
            invite: dmVm.invite,
            hasLoadedAllMessages: dmVm.hasLoadedAllMessages,
            profile: dmVm.profile,
            untitledConversationPlaceholder: dmVm.untitledConversationPlaceholder,
            conversationNamePlaceholder: dmVm.conversationNamePlaceholder,
            conversationName: $dmVm.editingConversationName,
            conversationImage: $dmVm.conversationImage,
            displayName: $dmVm.myProfileViewModel.editingDisplayName,
            messageText: $dmVm.messageText,
            messagePlaceholder: messagePlaceholder,
            pendingMediaAttachments: dmVm.pendingMediaAttachments,
            composerLinkPreview: dmVm.pastedLinkPreview,
            pendingInviteURL: dmVm.pendingInvite?.fullURL,
            pendingInviteConvoName: $dmVm.pendingInviteConvoName,
            pendingInviteImage: $dmVm.pendingInviteImage,
            pendingAgentShareName: dmVm.pendingAgentShare?.resolved?.displayName,
            pendingAgentShareEmoji: dmVm.pendingAgentShare?.resolved?.emoji,
            pendingAgentShareSummary: dmVm.pendingAgentShare?.resolved?.descriptionText,
            isShowingAgentShareChip: dmVm.pendingAgentShare != nil,
            onClearAgentShare: dmVm.clearPendingAgentShare,
            sendButtonEnabled: dmVm.sendButtonEnabled,
            sendButtonPaused: sendButtonPaused,
            onPausedSendTap: { showingPausedAgentAlert = true },
            profileImage: $dmVm.myProfileViewModel.profileImage,
            onboardingCoordinator: dmVm.onboardingCoordinator,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            messagesTextFieldEnabled: !isReadOnly,
            isReadOnly: isReadOnly,
            onUserInteraction: {
                dmVm.dismissQuickEditor()
                focusCoordinator.dismissQuickEditor()
            },
            onSendMessage: {
                dmVm.onSendMessage(focusCoordinator: focusCoordinator)
            },
            onClearInvite: dmVm.clearPendingInvite,
            onClearLinkPreview: { dmVm.pastedLinkPreview = nil },
            onClearMediaAttachment: dmVm.removeMediaAttachment(id:),
            onTapAvatar: dmVm.onTapAvatar(_:),
            onTapInvite: { _ in },
            messageLinkRouter: messageLinkRouter,
            conversationSpaceURL: conversationSpaceURL,
            agentShareResolver: dmVm.agentShareResolver,
            onReaction: dmVm.onReaction(emoji:messageId:),
            onToggleReaction: dmVm.onReaction(emoji:messageId:),
            onTapReactions: dmVm.onTapReactions(_:),
            onTapReadReceipts: dmVm.onTapReadReceipts(_:),
            onTapThinkingIndicator: { descriptor in
                dmVm.presentingThinkingDetail = descriptor
            },
            onReply: { message in
                dmVm.onReply(message)
                focusCoordinator.moveFocus(to: .message)
            },
            onOpenMessageDetail: { message in
                dmVm.presentingMessageDetail = message
            },
            expandedMessageIds: dmVm.expandedMessageIds,
            onToggleMessageExpanded: { messageId in
                dmVm.toggleMessageExpanded(messageId)
            },
            replyingToMessage: dmVm.replyingToMessage,
            replyingToAudioTranscriptText: dmVm.replyingToAudioTranscriptText,
            onCancelReply: dmVm.cancelReply,
            onDisplayNameEndedEditing: {
                dmVm.onDisplayNameEndedEditing(focusCoordinator: focusCoordinator, context: .quickEditor)
            },
            onProfileSettings: dmVm.onProfileSettings,
            onLoadPreviousMessages: dmVm.loadPreviousMessages,
            onPhotoDimensionsLoaded: dmVm.onPhotoDimensionsLoaded(_:width:height:),
            onPhotoSelected: dmVm.addPhotoAttachment(_:),
            onVideoSelected: dmVm.addVideoAttachment(url:),
            onFileSelected: dmVm.addFileAttachment(url:filename:mimeType:fileSize:),
            onAboutAgents: {},
            onAgentOutOfCredits: { dmVm.presentingPaywall = true },
            agentPowerDepletedByInboxId: dmVm.agentPowerDepletedByInboxId,
            onTapUpdateMember: { dmVm.presentingProfileForMember = $0 },
            onTapCapabilityConnect: { prompt in handleDmCapabilityConnectTap(prompt, dmVm: dmVm) },
            onRetryMessage: dmVm.retryMessage(_:),
            onDeleteMessage: dmVm.deleteMessage(_:),
            onRetryAgentJoin: {},
            onInviteAgent: {},
            onRetryTranscript: { item in
                dmVm.retryTranscript(for: item)
            },
            profileSheetForMember: { member in AnyView(memberContactDetailSheet(for: member, dmVm: dmVm)) },
            memberContactOverride: contactOverride(for: dmVm),
            isAgentJoinPending: false,
            // .suppressed is the one mode that hides every leading affordance
            // (.hidden still renders the "Invite members" pill).
            headerMode: .suppressed,
            onVoiceMemoTap: { dmVm.onVoiceMemoTapped() },
            voiceMemoRecorder: dmVm.voiceMemoRecorder,
            onSendVoiceMemo: { dmVm.sendVoiceMemo() },
            extraBottomInset: extraBottomInset,
            // Clearance for the conversation's floating top chrome, matching
            // the group transcript.
            topContentInset: topContentInset,
            // Same reason as the group transcript: the controller only adjusts
            // for safe area and tracks the keyboard when it owns its bottom bar.
            hostsBottomBar: true,
            // The DM's composer is the agent-style one: its `+` menu carries
            // the Connections row.
            usesAgentComposerLayout: true,
            connectionsEnabled: connectionsEnabled,
            onConnectionsTap: onConnectionsTap,
            hostRendersContextMenu: true,
            onContentHeightChanged: onContentHeightChanged,
            onScrollToBottomAvailable: onScrollToBottomAvailable,
            bottomBarContent: { EmptyView() }
        )
    }

    /// Attaches the DM view model's message-interaction sheets to the opaque
    /// result of `dmMessagesView`. Kept off the giant `MessagesView(...)`
    /// expression so the type-checker never re-solves that chain with four
    /// extra modifiers (the parent `ConversationView` binds these sheets to
    /// its own `viewModel`, so the DM page needs its own bound to `dmVm`).
    private func dmMessagesViewWithSheets(_ dmVm: ConversationViewModel) -> some View {
        @Bindable var dmVm = dmVm
        return dmMessagesView(dmVm)
            .sheet(item: $dmVm.presentingProfileForMember) { member in
                memberContactDetailSheet(for: member, dmVm: dmVm)
            }
            .sheet(isPresented: $dmVm.presentingProfileSettings) {
                ProfileSetupSheet(mode: .edit)
            }
            .selfSizingSheet(item: $dmVm.presentingReactionsForMessage) { message in
                reactionsDrawer(for: message, dmVm: dmVm)
            }
            .selfSizingSheet(item: $dmVm.presentingReadByForGroup) { group in
                readByDrawer(for: group, dmVm: dmVm)
            }
            .sheet(item: $dmVm.presentingThinkingDetail) { descriptor in
                thinkingDetail(for: descriptor, dmVm: dmVm)
            }
            .sheet(item: $dmVm.presentingMessageDetail) { message in
                messageDetail(for: message, dmVm: dmVm)
            }
            .sheet(isPresented: $dmVm.presentingPaywall) {
                paywall(for: dmVm)
            }
            .selfSizingSheet(isPresented: $dmVm.presentingCapabilityApproval) {
                capabilityApprovalSheet(for: dmVm)
            }
    }

    /// A pending pill in the DM transcript opens the same approval sheet the
    /// group path uses. Read-only viewers can't answer the request (a result
    /// message couldn't be sent on their behalf anyway).
    private func handleDmCapabilityConnectTap(_ prompt: CapabilityConnectPrompt, dmVm: ConversationViewModel) {
        guard !isReadOnly else { return }
        dmVm.onTapCapabilityConnectPrompt(prompt)
    }

    /// Mirrors `ConversationView.capabilityApprovalSheet` -- including the
    /// in-flight and error wiring and the named grant-scope disclosure. The
    /// DM approval scopes its grant to the origin group, and the sheet names
    /// that group before the approve control renders.
    @ViewBuilder
    private func capabilityApprovalSheet(for dmVm: ConversationViewModel) -> some View {
        if let layout = dmVm.pendingCapabilityPickerLayout {
            CapabilityApprovalSheetView(
                layout: layout,
                agentName: dmVm.askerDisplayName(for: layout.request),
                isApproving: dmVm.capabilityApprovalInFlight,
                approvalErrorMessage: dmVm.capabilityApprovalErrorMessage,
                scopeDisplayName: dmVm.capabilityApprovalScopeName,
                blockedMessage: dmVm.capabilityApprovalBlockedMessage,
                onApprove: { providerIds, bundleSelection in
                    dmVm.onCapabilityApprove(
                        providerIds: providerIds,
                        bundleSelection: bundleSelection
                    )
                }
            )
        } else {
            EmptyView()
        }
    }

    /// The low-balance paywall reached from the transcript's out-of-credits
    /// affordance. Bound to the DM view model because `onAgentOutOfCredits`
    /// sets `dmVm.presentingPaywall`; the parent `ConversationView` binds its
    /// own paywall to the origin view model. Mirrors ConversationView's paywall
    /// sheet.
    @ViewBuilder
    private func paywall(for dmVm: ConversationViewModel) -> some View {
        let paywallViewModel = PaywallViewModel(
            subscriptionService: SubscriptionServices.shared,
            paywallSource: .lowBalanceBanner,
            coreActions: dmVm.coreActions
        )
        PaywallView(viewModel: paywallViewModel)
    }

    /// The contact card for a tapped avatar. `onStartAgentDm` is nil: the
    /// only agent reachable from here is the one whose DM this already is.
    private func memberContactDetailSheet(
        for member: ConversationMember,
        dmVm: ConversationViewModel
    ) -> some View {
        MemberContactDetailSheetContent(
            viewModel: dmVm,
            member: member,
            profileSettingsViewModel: profileSettingsViewModel,
            onStartAgentDm: nil
        )
    }

    @ViewBuilder
    private func reactionsDrawer(for message: AnyMessage, dmVm: ConversationViewModel) -> some View {
        ReactionsDrawerView(message: message) { reaction in
            dmVm.removeReaction(reaction, from: message)
        }
    }

    @ViewBuilder
    private func readByDrawer(for group: MessagesGroup, dmVm: ConversationViewModel) -> some View {
        ReadByDrawerView(
            members: group.readByMembers,
            memberContactOverride: contactOverride(for: dmVm)
        )
    }

    @ViewBuilder
    private func thinkingDetail(for descriptor: ThinkingSessionDescriptor, dmVm: ConversationViewModel) -> some View {
        ThinkingDetailView(
            descriptor: descriptor,
            conversation: dmVm.conversation,
            viewModel: dmVm,
            onStop: { Task { await dmVm.interruptAgent() } },
            profileSheetForMember: { member in AnyView(memberContactDetailSheet(for: member, dmVm: dmVm)) }
        )
    }

    @ViewBuilder
    private func messageDetail(for message: AnyMessage, dmVm: ConversationViewModel) -> some View {
        MessageDetailView(
            message: message,
            onCopy: { text in
                UIPasteboard.general.string = text
            },
            onReply: { repliedMessage in
                dmVm.presentingMessageDetail = nil
                dmVm.onReply(repliedMessage)
                focusCoordinator.moveFocus(to: .message)
            }
        )
    }

    private enum Constant {
        /// The design's still frame fills 39 of the track's 120 points.
        static let progressStart: Double = 0.325
        static let progressCap: Double = 0.9
        static let progressStep: Double = 0.05
        static let progressTick: Double = 0.8
        static let progressWidth: CGFloat = 120.0
        static let progressHeight: CGFloat = 8.0
        static let progressTrackOpacity: Double = 0.3
    }
}

/// Presents the paused-agent alert as a UIKit `UIAlertController` we fully
/// control. A SwiftUI `.alert` inherits its button color from the presenting
/// controller's tintColor, which on the agent tab is forced dark
/// (ScreenAppearanceScope) - the app's colorTextPrimary tint resolves to white,
/// so the buttons read white on the light system alert. Pinning the alert to a
/// light appearance and tinting it with colorTextPrimary keeps title, message,
/// and buttons all dark. Embedded as a zero-size background so it never draws.
private struct PausedAgentAlert: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let agentName: String
    let onUnpause: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard isPresented else {
            if let alert = coordinator.alert {
                coordinator.alert = nil
                alert.dismiss(animated: true)
            }
            return
        }
        guard coordinator.alert == nil, host.presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "\(agentName) is paused",
            message: "Paused agents can't receive 1:1 messages nor see anything new in the groupchat",
            preferredStyle: .alert
        )
        alert.overrideUserInterfaceStyle = .light
        let okAction = UIAlertAction(title: "OK", style: .default) { _ in
            coordinator.alert = nil
            isPresented = false
        }
        alert.addAction(okAction)
        alert.addAction(UIAlertAction(title: "Unpause", style: .default) { _ in
            coordinator.alert = nil
            isPresented = false
            onUnpause()
        })
        // OK is the emphasized action: the preferred action renders filled with
        // the tint (black here) and white text, leaving Unpause the plain button.
        alert.preferredAction = okAction
        coordinator.alert = alert
        host.present(alert, animated: true)
        alert.view.tintColor = UIColor(named: "colorTextPrimary") ?? .label
    }

    final class Coordinator {
        weak var alert: UIAlertController?
    }
}
