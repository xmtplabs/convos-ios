import ConvosComposer
import ConvosCore
import SwiftUI

/// The Agent tab's backing view: the user's private DM with the
/// conversation's agent, rendered behind the conversation sheet. The DM is a
/// real 2-member conversation (see docs/plans/agent-dms.md).
///
/// The DM's lifecycle lives in `AgentDmSession`, owned by `ConversationView`
/// and shared with the sheet's `AgentComposerBar`: once the DM exists this
/// view renders the same `MessagesView` the group chat uses (composer
/// excluded - the sheet hosts it), so list layout, filtering, and
/// interactions behave identically. Before the agent-created DM syncs in it
/// shows the disclosure empty state while the sheet's composer sits
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
    /// Mirrors ConversationView's effectiveReadOnly: a removed or stale
    /// device must not be able to send into agent DMs.
    let isReadOnly: Bool
    /// True while the Agent tab is the selected tab. The backing views stay
    /// mounted across tab switches, so activation drives the read state and
    /// the active-DM push lane. (Composer focus transfers are owned by
    /// ConversationView's tab-change handler, through the focus
    /// coordinators.)
    let isActiveTab: Bool
    /// True while the conversation sheet rests collapsed, which puts this
    /// transcript behind the chrome.
    ///
    /// The read state keys off it, not off `isActiveTab` alone: nothing here has
    /// been read while it is true, so the lane must not be marked read nor claim
    /// to be the lane being read. Otherwise a bind landing while the sheet is
    /// down - the reconciler creating the DM as the user waits - would quietly
    /// clear the unread state its own arrival should have set.
    var isSheetCollapsed: Bool = false
    /// Owned by ConversationView so the sheet can hide while the DM's
    /// long-press context menu is presented.
    @Bindable var contextMenuState: MessageContextMenuState
    /// Focus shared with the sheet's agent composer; deliberately not the
    /// group composer's focus state, which stays mounted alongside this tab.
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    /// Bridges the DM transcript's scroll-to-bottom up to the sheet's
    /// composer, which fires it on send.
    var onScrollToBottomAvailable: ((@escaping (Bool) -> Void) -> Void)?
    /// Surfaces this transcript's content height, which caps how far the sheet
    /// opens on the Agent tab.
    var onContentHeightChanged: ((CGFloat) -> Void)?

    /// How much of this page's top the sheet is clipping away.
    ///
    /// The sheet hands its transcripts one constant, full-height frame at
    /// every detent, bottom-aligned, and clips whatever overflows its top
    /// edge (see `ConversationSheetContent.transcript`). The transcript wants
    /// that overflow - it scrolls content up through it - but the empty
    /// states below want it padded back out: centering in the full frame puts
    /// them in the band above the sheet, so at anything short of `full` they
    /// are clipped away entirely and the tab reads as blank.
    @Environment(\.transcriptClippedTopOverflow) private var clippedTopOverflow: CGFloat

    /// Fill of the preparing bar. Creeps while the agent is on its way; it
    /// tracks elapsed time, not real progress, since nothing reports any.
    @State private var preparingProgress: Double = Constant.progressStart

    private var agentName: String { session.agentName }

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
        .environment(\.colorScheme, .dark)
        // The agent-participation ("listen") control governs how much agents
        // speak in the group room; it has no meaning in a 1:1 agent DM, so clear
        // the inherited participation context to hide the control here.
        .environment(\.agentParticipation, nil)
        // The backing views mount on the tab's first visit with the tab
        // already active, so no isActiveTab change fires; handle the initial
        // activation (mark read, register the push-suppression lane) here.
        .onAppear {
            if isActiveTab, !isSheetCollapsed {
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
            guard dmId != nil, isActiveTab, !isSheetCollapsed else { return }
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
            // left. Unless the sheet was collapsed over it, where nothing was
            // on screen to have been read.
            if !isSheetCollapsed {
                session.markDmAsRead()
            }
            session.updateActiveDmLane(isActive: false)
            return
        }
        guard !isSheetCollapsed else { return }
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
        if session.agentInboxId != nil || session.isJoiningAgent {
            return .preparing
        }
        return .noAgent
    }

    /// Offered when the conversation has no agent at all (Figma 7488:14502).
    /// Centered in the sheet's visible band rather than in the full-height
    /// frame the sheet hands its transcripts - see `clippedTopOverflow`.
    private var addAgentState: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Button(action: session.requestAgentJoin) {
                Text("Add an agent")
                    .font(.footnote)
                    .foregroundStyle(.colorTextPrimaryInverted)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .frame(height: Constant.addAgentButtonHeight)
                    .background(.colorLava, in: .rect(cornerRadius: Constant.addAgentButtonRadius))
            }
            .accessibilityIdentifier("agent-dm-add-agent-button")
            Text("To help the group out")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.colorLava)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Inset to the band the sheet is showing - the clipped overflow off
        // the top, the chrome's clearance off the bottom - so this centers in
        // what the reader can see and follows the sheet's edge as it resizes.
        // The background sits outside both, so the dark surface still fills
        // the clipped region.
        .padding(.top, clippedTopOverflow)
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
        // Inset to the band the sheet is showing - the clipped overflow off
        // the top, the chrome's clearance off the bottom - so this centers in
        // what the reader can see and follows the sheet's edge as it resizes.
        // The background sits outside both, so the dark surface still fills
        // the clipped region.
        .padding(.top, clippedTopOverflow)
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
    /// origin-conversation concepts; the DM leads with the disclosure cell
    /// instead (see docs/plans/agent-dms.md).
    private func dmItems(_ dmVm: ConversationViewModel) -> [MessagesListItemType] {
        var items = dmVm.messagesWithThinkingIndicators.compactMap { (item: MessagesListItemType) -> MessagesListItemType? in
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
        items.insert(.agentDmInfo(agentName: agentName), at: 0)
        return items
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
            messagePlaceholder: "Chat with \(agentName)",
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
            hostsBottomBar: false,
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
        static let addAgentButtonHeight: CGFloat = 36.0
        static let addAgentButtonRadius: CGFloat = 24.0
    }
}
