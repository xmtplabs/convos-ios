import ConvosCore
import SwiftUI

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
        isPresented: Binding<Bool>
    ) -> some View {
        modifier(AddFromContactsPickerModifier(viewModel: viewModel, isPresented: isPresented))
    }
}

private struct AddFromContactsPickerModifier: ViewModifier {
    @Bindable var viewModel: ConversationViewModel
    @Binding var isPresented: Bool

    @State private var errorMessage: String?
    @State private var presentingError: Bool = false

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
            onConfirm: handleConfirm
        )
    }

    private func handleConfirm(_ inboxIds: Set<String>, _ agentTemplateId: String?) {
        // Selecting an agent spawns a fresh instance of its template into
        // this conversation (the picker already showed the "one agent, many
        // convos" confirmation). Humans are added as members; both can be
        // present in a single confirm. At most one agent per conversation -
        // skip the spawn if this conversation already has one (the canonical
        // agent row can collapse a different instance than the one in chat,
        // so the picker's already-in-chat filter doesn't catch this).
        if let agentTemplateId, !viewModel.conversation.hasAgent {
            viewModel.requestAgentJoin(templateId: agentTemplateId)
        }
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
