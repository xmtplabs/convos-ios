import ConvosComposer
import ConvosCore
import SwiftUI

/// The Agent tab's bar in the conversation sheet. Once the agent DM exists
/// this is the full composer bound to the DM's view model; before then it is
/// the same bar disabled - the agent owns DM creation, so the client cannot
/// send until the agent-created DM syncs in. Enabling it earlier would let a
/// send silently no-op, since there is no DM to send into yet.
struct AgentComposerBar: View {
    let session: AgentDmSession
    let conversationId: String
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let isReadOnly: Bool
    /// Scrolls the DM transcript to the bottom; invoked on send.
    var scrollToBottom: (() -> Void)?

    /// Non-production switcher/demo state. Nil in production, where the bar
    /// keeps its existing single-agent behavior until the server contracts are
    /// live.
    var prototypeState: AgentChatPrototypeState?
    var lanes: [AgentChatLane] = []
    var selectedLane: AgentChatLane?
    var onSelectLane: (AgentChatLane) -> Void = { _ in }

    @State private var isSwitcherPresented: Bool = false
    @State private var isPersonalContextPresented: Bool = false

    var body: some View {
        if let prototypeState, let selectedLane {
            prototypeBar(state: prototypeState, selectedLane: selectedLane)
        } else if let dmViewModel = session.dmViewModel {
            ConversationComposerBar(
                viewModel: dmViewModel,
                focusState: $focusState,
                focusCoordinator: focusCoordinator,
                messagesTextFieldEnabled: !isReadOnly,
                messagePlaceholder: "Chat with \(session.agentName)",
                isGroupComposer: false,
                scrollToBottom: scrollToBottom,
                usesInlineMediaButtons: true,
                extraBarContent: { EmptyView() }
            )
        } else {
            draftComposer
        }
    }

    private func prototypeBar(
        state: AgentChatPrototypeState,
        selectedLane: AgentChatLane
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            prototypeComposer(state: state, selectedLane: selectedLane)
                .padding(.leading, Constant.avatarGutter)

            Button {
                isSwitcherPresented = true
            } label: {
                AgentChatLaneAvatar(lane: selectedLane)
                    .overlay {
                        Circle()
                            .stroke(Color.colorBorderSubtle, lineWidth: 1)
                    }
                    .contentShape(.circle)
            }
            .frame(width: Constant.avatarButtonSize, height: Constant.avatarButtonSize)
            .padding(.leading, DesignConstants.Spacing.step4x)
            .padding(.bottom, Constant.avatarBottomInset)
            .accessibilityLabel("Switch agent. Current: \(selectedLane.name)")
            .accessibilityHint("Opens the agent and Ghost Mode list")
            .accessibilityIdentifier("agent-chat-switcher-button")
        }
        .sheet(isPresented: $isSwitcherPresented) {
            AgentSwitcherSheet(
                lanes: lanes,
                selectedLane: selectedLane,
                prototypeState: state,
                conversationId: conversationId,
                onSelect: onSelectLane
            )
        }
        .fullScreenCover(isPresented: $isPersonalContextPresented) {
            PersonalContextSuggestionView(
                conversationId: conversationId,
                approvedItemIds: state.approvedPersonalContextItemIds,
                onApproved: { bundle in
                    state.approvePersonalContext(bundle)
                    PersonalContextPrototypeStore.save(
                        state.approvedPersonalContextItemIds,
                        for: conversationId
                    )
                    isPersonalContextPresented = false
                },
                onRemoved: {
                    state.removePersonalContextAccess()
                    PersonalContextPrototypeStore.removeAccess(for: conversationId)
                    isPersonalContextPresented = false
                }
            )
        }
        .onAppear {
            state.restorePersonalContext(
                itemIds: PersonalContextPrototypeStore.approvedItemIds(for: conversationId)
            )
        }
    }

    @ViewBuilder
    private func prototypeComposer(
        state: AgentChatPrototypeState,
        selectedLane: AgentChatLane
    ) -> some View {
        if selectedLane.isLocalPrototype {
            AgentChatDemoComposer(
                lane: selectedLane,
                prototypeState: state,
                focusState: $focusState,
                onUsePersonalContext: { isPersonalContextPresented = true }
            )
        } else if let dmViewModel = session.dmViewModel {
            ConversationComposerBar(
                viewModel: dmViewModel,
                focusState: $focusState,
                focusCoordinator: focusCoordinator,
                messagesTextFieldEnabled: !isReadOnly,
                messagePlaceholder: "Chat with \(selectedLane.name)",
                isGroupComposer: false,
                scrollToBottom: scrollToBottom,
                usesInlineMediaButtons: true,
                extraBarContent: { EmptyView() }
            )
        } else {
            draftComposer(agentName: selectedLane.name)
        }
    }

    /// Disabled composer for the not-yet-created DM. The field and send
    /// button stay disabled until the session binds the real conversation
    /// (normally within a second or two of the agent joining). The media
    /// buttons stay visible (inert, dimmed) so the composer keeps the
    /// agent bar's shape rather than dropping the affordances.
    private var draftComposer: some View {
        draftComposer(agentName: session.agentName)
    }

    private func draftComposer(agentName: String) -> some View {
        MessagesInputView(
            displayName: .constant(""),
            emptyDisplayNamePlaceholder: "",
            messagePlaceholder: "Chat with \(agentName)",
            messageText: .constant(""),
            pendingInviteConvoName: .constant(""),
            pendingInviteImage: .constant(nil),
            sendButtonEnabled: false,
            focusState: $focusState,
            messagesTextFieldEnabled: false,
            onSendMessage: {},
            onClearInvite: {},
            fileAttachmentPreview: { _ in EmptyView() },
            agentShareChip: { EmptyView() },
            attachmentsButton: { draftMediaButtons }
        )
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.rect(cornerRadius: Constant.draftCornerRadius))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Constant.draftCornerRadius))
        // Mirrors MessagesBottomBar's composer padding (16 horizontal, none
        // vertical) so the sheet keeps one height across the Group tab and
        // the pre-creation Agent tab.
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    /// The media buttons in the pre-creation composer: kept visible so the
    /// bar holds the agent style's shape, but inert and dimmed (no
    /// conversation to attach to yet) to read as disabled alongside the
    /// field. Mirrors `MessagesBottomBar.inlineMediaButtons`.
    private var draftMediaButtons: some View {
        HStack(spacing: 0) {
            ForEach(["camera.fill", "photo.fill", "document.fill"], id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 18.0, weight: .medium))
                    .foregroundStyle(Color.colorTextPrimary)
                    .frame(width: 32, height: 32)
            }
        }
        .opacity(0.4)
    }

    private enum Constant {
        static let draftCornerRadius: CGFloat = 26.0
        static let avatarButtonSize: CGFloat = 44.0
        /// 44pt avatar + 8pt breathing room. The composer's own 16pt inset
        /// remains on its right edge; this only makes room on the left.
        static let avatarGutter: CGFloat = 52.0
        /// The input itself is 52pt high; center the 44pt avatar against it.
        static let avatarBottomInset: CGFloat = 4.0
    }
}
