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
    @FocusState.Binding var focusState: MessagesViewInputFocus?
    let focusCoordinator: FocusCoordinator
    let isReadOnly: Bool
    /// Host-passed capability gating the composer's `+` menu `.connections`
    /// row; read from the feature flag at the `ConversationView` seam only.
    let connectionsEnabled: Bool
    /// Presents the Connections browser modal; the host owns the
    /// presentation, the composer only emits the tap.
    let onConnectionsTap: () -> Void
    /// Scrolls the DM transcript to the bottom; invoked on send.
    var scrollToBottom: (() -> Void)?

    var body: some View {
        if let dmViewModel = session.dmViewModel {
            ConversationComposerBar(
                viewModel: dmViewModel,
                focusState: $focusState,
                focusCoordinator: focusCoordinator,
                messagesTextFieldEnabled: !isReadOnly,
                messagePlaceholder: "Chat with \(session.agentName)",
                isGroupComposer: false,
                scrollToBottom: scrollToBottom,
                usesAgentComposerLayout: true,
                connectionsEnabled: connectionsEnabled,
                onConnectionsTap: onConnectionsTap,
                extraBarContent: { EmptyView() }
            )
        } else {
            draftComposer
        }
    }

    /// Disabled composer for the not-yet-created DM. The field and send
    /// button stay disabled until the session binds the real conversation
    /// (normally within a second or two of the agent joining). The `+` stays
    /// visible (inert, dimmed) so the composer keeps the agent bar's shape
    /// rather than dropping the affordance.
    private var draftComposer: some View {
        MessagesInputView(
            displayName: .constant(""),
            emptyDisplayNamePlaceholder: "",
            messagePlaceholder: "Chat with \(session.agentName)",
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
            attachmentsButton: { draftPlusGlyph }
        )
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.rect(cornerRadius: Constant.draftCornerRadius))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Constant.draftCornerRadius))
        // Mirrors MessagesBottomBar's composer padding (16 horizontal, none
        // vertical) so the sheet keeps one height across the Group tab and
        // the pre-creation Agent tab.
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    /// The `+` in the pre-creation composer: kept visible so the bar holds
    /// the agent layout's shape, but inert and dimmed (no conversation to
    /// attach to yet). Mirrors `MessagesBottomBar.attachmentsGlyph`.
    private var draftPlusGlyph: some View {
        Image(systemName: "plus")
            .font(.system(size: 18.0, weight: .medium))
            .foregroundStyle(Color.colorTextPrimary)
            .frame(width: 32, height: 32)
            .opacity(0.4)
    }

    private enum Constant {
        static let draftCornerRadius: CGFloat = 26.0
    }
}
