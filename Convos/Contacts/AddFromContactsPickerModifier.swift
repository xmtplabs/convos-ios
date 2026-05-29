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
            agentTemplateContactsRepository: viewModel.messagingService.agentTemplateContactsRepository(),
            alreadyInChatInboxIds: alreadyInChat,
            onConfirm: handleConfirm
        )
    }

    /// Splits the mixed selection into humans and agent templates. Humans
    /// go through the existing `addMembersFromContacts` flow. Templates go
    /// through `requestAgentJoins(templateIds:)` -- the batched (serialized)
    /// variant -- which reuses the existing conversation's invite slug to
    /// spawn a fresh instance per templateId (no new backend endpoint, see
    /// Phase 2 PRD add-to-existing question 1).
    ///
    /// Important: do NOT loop `requestAgentJoin(templateId:)` here. That
    /// method is single-flight (each call cancels the prior task), so a
    /// for-loop ends up running only the LAST templateId to completion --
    /// every prior call gets `URLError.cancelled` mid-dispatch and silently
    /// dropped.
    private func handleConfirm(_ selection: Set<ContactsPickerViewModel.Selection>) {
        let humanInboxIds: [String] = selection.compactMap(\.inboxId)
        let templateIds: [String] = selection.compactMap(\.templateId)
        guard !humanInboxIds.isEmpty || !templateIds.isEmpty else { return }

        if !templateIds.isEmpty {
            viewModel.requestAgentJoins(templateIds: templateIds)
        }

        guard !humanInboxIds.isEmpty else { return }
        Task {
            do {
                try await viewModel.addMembersFromContacts(humanInboxIds)
            } catch {
                Log.error("Add from contacts failed: \(error.localizedDescription)")
                errorMessage = "We couldn't add those contacts. Please try again."
                presentingError = true
            }
        }
    }
}
