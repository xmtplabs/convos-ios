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
                extraBarContent: { EmptyView() }
            )
        } else {
            draftComposer
        }
    }

    /// Disabled composer for the not-yet-created DM. The field and send
    /// button stay disabled until the session binds the real conversation
    /// (normally within a second or two of the agent joining). The `+` stays
    /// visible (inert) so the composer keeps its normal shape rather than
    /// dropping the attachments affordance.
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
            attachmentsButton: { draftAttachmentsGlyph }
        )
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.rect(cornerRadius: Constant.draftCornerRadius))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Constant.draftCornerRadius))
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
    }

    /// The `+` glyph in the pre-creation composer: kept visible so the bar
    /// holds its normal shape, but inert and dimmed (no conversation to
    /// attach to yet) to read as disabled alongside the field and send
    /// button. Mirrors `MessagesBottomBar.attachmentsGlyph`.
    private var draftAttachmentsGlyph: some View {
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
