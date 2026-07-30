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
    /// Clearance for the pager dots floating under the composer. Owned by
    /// ConversationView because it is keyboard-aware there (the dots hide when
    /// the keyboard is up, so the inset drops to zero -- a fixed value would
    /// leave the DM transcript floating above the composer while typing).
    let extraBottomInset: CGFloat
    /// Mirrors ConversationView's effectiveReadOnly: a removed or stale
    /// device must not be able to create agent DMs or send into them.
    let isReadOnly: Bool
    /// True when this DM page is the pager's selected page. Every page stays
    /// mounted in the paging HStack, so each page owns its composer focus and
    /// releases it when it is no longer the active page - otherwise the DM
    /// composer would keep the keyboard up after the user pages back to the
    /// group chat, and vice versa.
    let isActivePage: Bool
    /// Whether a composer keyboard was up when this page became active. Used to
    /// transfer the keyboard onto the DM composer when the user pages in mid-edit,
    /// while a keyboard-down glance at the DM leaves the keyboard down.
    let keyboardVisible: Bool

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

    private var agent: ConversationMember? {
        viewModel.conversation.members.first { $0.profile.inboxId == agentInboxId }
    }

    private var agentName: String {
        agent?.profile.displayName ?? "Assistant"
    }

    var body: some View {
        Group {
            if let dmViewModel {
                dmMessagesViewWithSheets(dmViewModel)
            } else {
                emptyStateWithComposer
            }
        }
        .onAppear(perform: bindExistingDm)
        .task(id: agentInboxId) { await rebindWhenDmAppears() }
        .onChange(of: isActivePage) { _, active in
            handleActivePageChange(active)
        }
    }

    /// Transfers composer focus onto this DM page when it becomes active while a
    /// keyboard was already up (the user paged in mid-edit), and clears focus when
    /// the page is paged away so the DM keyboard doesn't linger over the group
    /// chat. A keyboard-down arrival honors the platform default (nil on iPhone),
    /// so glancing at the DM doesn't raise the keyboard unprompted.
    private func handleActivePageChange(_ active: Bool) {
        guard active else {
            focusState = nil
            return
        }
        focusState = keyboardVisible ? .message : focusCoordinator.defaultFocus
    }

    /// The eager reconciler (or another device) can create the DM while this
    /// page is already mounted; a single onAppear bind would leave the page on
    /// the empty state until remount. Re-attempt the bind on every repository
    /// emission until it succeeds.
    private func rebindWhenDmAppears() async {
        guard dmViewModel == nil else { return }
        let publisher = viewModel.session
            .conversationsRepository(for: [.allowed, .unknown])
            .conversationsPublisher
        for await _ in publisher.values {
            if Task.isCancelled || dmViewModel != nil { return }
            bindExistingDm()
            if dmViewModel != nil { return }
        }
    }

    private func bindExistingDm() {
        guard dmViewModel == nil else { return }
        guard let existing = try? viewModel.session
            .conversationsRepository(for: [.allowed, .unknown])
            .findAgentDm(with: agentInboxId) else {
            return
        }
        dmViewModel = makeDmViewModel(for: existing)
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
    /// before the DM exists - so the empty state is literally the list's
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
                // first group (synthesizing an empty one when needed) - an
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
        !isReadOnly && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreatingDm
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
            messagesTextFieldEnabled: !isReadOnly && !isCreatingDm,
            onSendMessage: handleDraftSend,
            onClearInvite: {},
            fileAttachmentPreview: { _ in EmptyView() },
            agentShareChip: { EmptyView() },
            attachmentsButton: { EmptyView() }
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
        isCreatingDm = true
        Task {
            defer { isCreatingDm = false }
            do {
                let conversationId = try await AgentDmFlow.startOrFindDm(
                    agentInboxId: agentInboxId,
                    originConversationId: viewModel.conversation.id,
                    session: viewModel.session
                )
                _ = conversationId
                // Bind to whatever DM now exists for this agent, not only the
                // one this send created: the eager reconciler can win the
                // create race, and converging on the surviving DM both keeps
                // the message and avoids stranding it in a conversation the
                // backend's dedup will make the agent leave.
                guard let conversation = try viewModel.session
                    .conversationsRepository(for: [.allowed, .unknown])
                    .findAgentDm(with: agentInboxId) else {
                    Log.error("Agent DM created but not found for binding")
                    await MainActor.run { draftText = text }
                    return
                }
                let dmVm = makeDmViewModel(for: conversation)
                dmViewModel = dmVm
                dmVm.messageText = text
                dmVm.onSendMessage(focusCoordinator: focusCoordinator)
            } catch {
                Log.error("Failed to start agent DM: \(error.localizedDescription)")
                await MainActor.run { draftText = text }
            }
        }
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
            extraBottomInset: extraBottomInset,
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
            profileSheetForMember: { _ in AnyView(EmptyView()) }
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
}
