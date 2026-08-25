import ConvosCore
import SwiftUI
import UIKit

// MARK: - Module overview
//
// `AddFromContactsPickerModifier` consolidates the sheet + alert + confirm
// plumbing required to present the contacts picker scoped to an existing
// conversation. Three surfaces in `Convos/Conversation Detail/` use it:
//
//   1. `ConversationView` (chat header plus-menu)
//   2. `ConversationInfoView` (settings page plus-menu)
//   3. `ConversationMembersListView` (members list plus-menu)
//
// All three share the same `ConversationViewModel`, so the modifier owns the
// picker `@State`, the error alert `@State`, and the confirm handler. Each
// surface only needs to flip a `Bool` from its menu's `onAddFromContacts`.
//
// Mirrors the "one component, two-or-more entry points" pattern documented
// in `ContactsPickerView` and `ContactDetailView` (see `ContactsPickerMode`,
// `ContactDetailMode`).

extension View {
    /// Presents `ContactsPickerView` (mode: `.addToConversation`) when
    /// `isPresented` flips to `true`, and surfaces an alert if the
    /// subsequent `addMembersFromContacts` call fails. The picker is
    /// pre-filtered to the conversation's existing members so they appear
    /// inline-disabled in the list.
    func addFromContactsPicker(
        viewModel: ConversationViewModel,
        isPresented: Binding<Bool>,
        onInviteShared: (() -> Void)? = nil,
    ) -> some View {
        modifier(AddFromContactsPickerModifier(
            viewModel: viewModel,
            isPresented: isPresented,
            onInviteShared: onInviteShared
        ))
    }
}

private struct AddFromContactsPickerModifier: ViewModifier {
    @Bindable var viewModel: ConversationViewModel
    @Binding var isPresented: Bool
    /// Called when the "Send an invite" share completes successfully, so a
    /// fresh embedded-invite conversation records the share and survives the
    /// empty-convo teardown. Nil for existing conversations, which are never
    /// discarded.
    let onInviteShared: (() -> Void)?
    @State private var errorMessage: String?
    @State private var presentingError: Bool = false
    @State private var presentingShareSheet: Bool = false
    /// Drives the invite-code sheet the "Show an invite code" row presents.
    @State private var presentingInviteCode: Bool = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) { pickerSheet }
            .alert(
                "Couldn't add contacts",
                isPresented: $presentingError,
                presenting: errorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    @ViewBuilder
    private var pickerSheet: some View {
        let alreadyInChat: Set<String> = Set(viewModel.conversation.members.map(\.profile.inboxId))
        ContactsPickerView(
            mode: .addToConversation(
                conversationId: viewModel.conversation.id,
                conversationTitle: viewModel.conversation.name
            ),
            contactsRepository: viewModel.messagingService.contactsRepository(),
            alreadyInChatInboxIds: alreadyInChat,
            title: "Invite",
            onShowInviteCode: handleShowInviteCode,
            onSendInvite: handleSendInvite,
            onConfirm: handleConfirm
        )
        // Hosted inside the picker sheet so "Send an invite" presents the share
        // sheet directly over the picker, rather than dismissing the picker
        // first and presenting from the parent once the modal settles.
        .shareSheet(
            isPresented: $presentingShareSheet,
            items: shareItems,
            onCompletion: { activityType, completed, _ in
                ConversationShareReporter.report(
                    activityType: activityType,
                    completed: completed,
                    invite: viewModel.invite,
                    conversation: viewModel.conversation,
                    coreActions: viewModel.coreActions
                )
                if completed { onInviteShared?() }
            }
        )
        // Presented from inside the picker for the same reason the share
        // sheet is: the code opens over the picker rather than waiting for it
        // to dismiss and reopening from the parent.
        .sheet(isPresented: $presentingInviteCode) {
            InviteCodeSheet(
                conversation: viewModel.conversation,
                invite: viewModel.invite,
                onShareCompleted: { completed in
                    if completed { onInviteShared?() }
                }
            )
        }
    }

    /// The current conversation's signed invite link, shared directly by the
    /// "Send an invite" row. Empty until the invite hydrates.
    private var shareItems: [Any] {
        let invite = viewModel.invite
        guard !invite.isEmpty else { return [] }
        return [invite.inviteURLString]
    }

    private func handleShowInviteCode() {
        // A full conversation can't mint new invite links, so even if the
        // sheet is reached, the invite code can't be shown.
        guard !viewModel.conversation.isFull else { return }
        presentingInviteCode = true
    }

    private func handleSendInvite() {
        // A full conversation can't share new invite links, so even if the
        // sheet is reached, the send-invite share is suppressed.
        guard !viewModel.conversation.isFull else { return }
        guard !viewModel.invite.isEmpty else { return }
        presentingShareSheet = true
    }

    private func handleConfirm(_ inboxIds: Set<String>, _ agentTemplateIds: [String]) {
        // Selecting agents spawns a fresh instance of each template into
        // this conversation (the picker already showed the "one agent, many
        // convos" confirmation). Humans are added as members; both can be
        // present in a single confirm.
        viewModel.requestAgentJoins(templateIds: agentTemplateIds)
        let ids = Array(inboxIds)
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await viewModel.addMembersFromContacts(ids)
            } catch {
                Log.error("Add from contacts failed: \(error.localizedDescription)")
                errorMessage = "We couldn't add those contacts. Please try again."
                presentingError = true
            }
        }
    }
}
