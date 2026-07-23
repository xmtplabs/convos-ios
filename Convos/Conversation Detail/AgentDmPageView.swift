import ConvosComposer
import ConvosCore
import SwiftUI

/// The agent-DM page inside `ConversationPager`: the user's private DM with
/// the conversation's agent, rendered as a page of the origin conversation.
/// The DM is a real 2-member conversation (see docs/plans/agent-dms.md).
///
/// Once the DM exists this page hosts a full `ConversationViewModel` for it
/// and renders the same `MessagesView` the chat page uses, so list layout,
/// filtering, composer, and interactions behave identically. Before the DM
/// exists it shows the disclosure empty state with a lightweight composer;
/// the first send creates the DM and swaps the full chat in.
struct AgentDmPageView: View {
    @Bindable var viewModel: ConversationViewModel
    let agentInboxId: String

    @State private var dmViewModel: ConversationViewModel?
    @State private var contextMenuState: MessageContextMenuState = .init()
    /// Local focus state, deliberately not shared with the chat composer:
    /// every pager page stays mounted in the paging HStack, so a shared
    /// focus value would fight with the chat page's text field.
    @FocusState private var focusState: MessagesViewInputFocus?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: .compact)
    @State private var draftText: String = ""
    @State private var isCreatingDm: Bool = false
    @State private var draftPhotoPickerPresented: Bool = false
    /// A message typed into the draft composer before eager creation finished.
    /// Handed to the real view model (whose optimistic UI renders it) as soon
    /// as the DM binds, so nothing waits on the network round-trips.
    @State private var queuedDraftMessage: String?

    private var agent: ConversationMember? {
        viewModel.conversation.members.first { $0.profile.inboxId == agentInboxId }
    }

    private var agentName: String {
        agent?.profile.displayName ?? "Assistant"
    }

    var body: some View {
        Group {
            if let dmViewModel {
                dmMessagesView(dmViewModel)
            } else {
                emptyStateWithComposer
            }
        }
        .onAppear(perform: bindExistingDm)
    }

    private func bindExistingDm() {
        guard dmViewModel == nil else { return }
        if let existing = try? viewModel.session
            .conversationsRepository(for: [.allowed, .unknown])
            .findAgentDm(with: agentInboxId) {
            dmViewModel = makeDmViewModel(for: existing)
            return
        }
        // The agent is already in the origin conversation, so the DM should
        // exist without waiting for a first message: create it eagerly on
        // appear. By the time the user types, the real view model is bound and
        // its own optimistic-send UI handles the message.
        ensureDm(thenSend: nil)
    }

    private func makeDmViewModel(for conversation: Conversation) -> ConversationViewModel {
        ConversationViewModel(
            conversation: conversation,
            session: viewModel.session,
            messagingService: viewModel.messagingService,
            coreActions: viewModel.coreActions
        )
    }

    // MARK: - Pre-creation

    /// The same disclosure cell the transcript leads with, standing alone
    /// before the DM exists — so the empty state is literally the list's
    /// first cell.
    private var emptyStateWithComposer: some View {
        ScrollView {
            AgentDmInfoCellView(agentProfile: agent?.profile, agentVerification: agent?.agentVerification ?? .unverified, agentName: agentName)
                .padding(.top, DesignConstants.Spacing.step16x)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.colorBackgroundSurfaceless)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            draftComposer
        }
    }

    /// The DM transcript: membership, invite, and agent-presence cells are
    /// origin-conversation concepts; the DM leads with the disclosure cell
    /// instead (see docs/plans/agent-dms.md).
    private func dmItems(_ dmVm: ConversationViewModel) -> [MessagesListItemType] {
        var items = dmVm.messagesWithThinkingIndicators.compactMap { (item: MessagesListItemType) -> MessagesListItemType? in
            switch item {
            case .invite, .update, .agentPresentInfo, .conversationInfo, .agentJoinStatus:
                return nil
            case .messages(var group):
                // The processor pins the agent contact card to the agent's
                // first group (synthesizing an empty one when needed) — an
                // origin-conversation affordance the info cell replaces here.
                group.agentContactCard = nil
                guard !group.messages.isEmpty else { return nil }
                return .messages(group)
            default:
                return item
            }
        }
        items.insert(.agentDmInfo(agentProfile: agent?.profile, agentVerification: agent?.agentVerification ?? .unverified, agentName: agentName), at: 0)
        return items
    }

    private var draftSendEnabled: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreatingDm
    }

    /// Minimal composer for the not-yet-created DM; the first send creates
    /// the conversation and hands the text to the full view model.
    private var draftComposer: some View {
        MessagesInputView(
            displayName: .constant(""),
            emptyDisplayNamePlaceholder: "",
            messagePlaceholder: "Chat with \(agentName)",
            messageText: $draftText,
            pendingInviteConvoName: .constant(""),
            pendingInviteImage: .constant(nil),
            sendButtonEnabled: draftSendEnabled,
            focusState: $focusState,
            messagesTextFieldEnabled: !isCreatingDm,
            onSendMessage: handleDraftSend,
            onClearInvite: {},
            fileAttachmentPreview: { _ in EmptyView() },
            agentShareChip: { EmptyView() }
        )
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.rect(cornerRadius: 26.0))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26.0))
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.bottom, DesignConstants.Spacing.step3x)
    }

    private func handleDraftSend() {
        let text = draftText
        draftText = ""
        // Eager creation usually has the DM bound by now: send straight through
        // the real view model's optimistic-send path. Otherwise queue the text
        // and let the in-flight creation send it the moment it binds.
        if let dmVm = dmViewModel {
            dmVm.messageText = text
            dmVm.onSendMessage(focusCoordinator: focusCoordinator)
            return
        }
        ensureDm(thenSend: text)
    }

    /// Idempotent, single-in-flight DM creation. Called eagerly on appear
    /// (`thenSend` nil) and by the draft composer (`thenSend` text) if the user
    /// sends before creation lands. Binds the real view model and sends any
    /// queued draft through its optimistic-send UI once the DM exists.
    private func ensureDm(thenSend text: String?) {
        if let text { queuedDraftMessage = text }
        guard !isCreatingDm else { return }
        isCreatingDm = true
        Task {
            defer { isCreatingDm = false }
            do {
                let conversationId = try await AgentDmFlow.startOrFindDm(
                    agentInboxId: agentInboxId,
                    originConversationId: viewModel.conversation.id,
                    session: viewModel.session
                )
                guard let conversation = try viewModel.session
                    .conversationsRepository(for: [.allowed, .unknown])
                    .findAgentDm(with: agentInboxId), conversation.id == conversationId else {
                    Log.error("Agent DM created but not found for binding")
                    restoreQueuedDraft()
                    return
                }
                let dmVm = dmViewModel ?? makeDmViewModel(for: conversation)
                if let queued = queuedDraftMessage {
                    dmVm.messageText = queued
                    dmVm.onSendMessage(focusCoordinator: focusCoordinator)
                    queuedDraftMessage = nil
                }
                dmViewModel = dmVm
            } catch {
                Log.error("Failed to start agent DM: \(error.localizedDescription)")
                restoreQueuedDraft()
            }
        }
    }

    private func restoreQueuedDraft() {
        if let queued = queuedDraftMessage, draftText.isEmpty {
            draftText = queued
        }
        queuedDraftMessage = nil
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
            pendingInviteConvoName: $dmVm.pendingInviteConvoName,
            pendingInviteImage: $dmVm.pendingInviteImage,
            sendButtonEnabled: dmVm.sendButtonEnabled,
            profileImage: $dmVm.myProfileViewModel.profileImage,
            onboardingCoordinator: dmVm.onboardingCoordinator,
            focusState: $focusState,
            focusCoordinator: focusCoordinator,
            messagesTextFieldEnabled: true,
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
            onTapAvatar: { _ in },
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
            creditsDepleted: dmVm.creditsDepleted,
            onTapUpdateMember: { _ in },
            onRetryMessage: dmVm.retryMessage(_:),
            onDeleteMessage: dmVm.deleteMessage(_:),
            onRetryAgentJoin: {},
            onCopyInviteLink: {},
            onConvoCode: {},
            onInviteAgent: {},
            onRetryTranscript: { item in
                dmVm.retryTranscript(for: item)
            },
            profileSheetForMember: { _ in AnyView(EmptyView()) },
            memberContactOverride: contactOverride(for: dmVm),
            isAgentJoinPending: false,
            // .suppressed is the one mode that hides every leading affordance
            // (.hidden still renders the "Invite members" pill).
            headerMode: .suppressed,
            onVoiceMemoTap: { dmVm.onVoiceMemoTapped() },
            voiceMemoRecorder: dmVm.voiceMemoRecorder,
            onSendVoiceMemo: { dmVm.sendVoiceMemo() },
            extraBottomInset: Constant.pagerDotsInset,
            bottomBarContent: { EmptyView() }
        )
    }

    private enum Constant {
        /// Clearance for the pager dots floating under the composer.
        static let pagerDotsInset: CGFloat = 24.0
    }
}

