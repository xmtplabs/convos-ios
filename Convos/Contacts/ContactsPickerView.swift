import ConvosCore
import SwiftUI

// MARK: - Module overview
//
// `ContactsPickerView` is the canonical multi-select contact picker.
// It is invoked from three entry points, parameterized by `ContactsPickerMode`:
//
//   1. Compose toolbar on the contacts list (`ContactsView` toolbar `+`),
//      `mode: .newConversation`. Confirm posts
//      `.contactsRequestedNewConversation` with the chosen inbox IDs;
//      `ConversationsViewModel` reacts by presenting a
//      `NewConversationView` driven by
//      `NewConversationViewModel(mode: .newConversationWithMembers(...))`.
//   2. Send-a-message CTA on the contact card (`ContactCardView`, either
//      standalone or scoped), `mode: .newConversation` with
//      `preselectedInboxIds: [contact.inboxId]`.
//   3. Add from Contacts in the chat plus-menu (`ConversationView` ->
//      `AddToConversationMenu.onAddFromContacts`), `mode:
//      .addToConversation(...)` with the conversation's existing members
//      passed as `alreadyInChatInboxIds`. Confirm calls
//      `ConversationViewModel.addMembersFromContacts(_:)`.
//
// Mirrors `ContactCardMode`'s "one component, two-or-more entry points"
// pattern. The view itself is presentation-only; callers own the side
// effect on confirm by passing in `onConfirm`.

/// Multi-select contact picker. See module-overview comment above for
/// entry-point mapping and the role each mode plays.
struct ContactsPickerView: View {
    @State private var viewModel: ContactsPickerViewModel
    @Environment(\.dismiss) private var dismiss: DismissAction

    let onConfirm: (_ inboxIds: Set<String>) -> Void

    init(
        mode: ContactsPickerMode,
        contactsRepository: any ContactsRepositoryProtocol,
        alreadyInChatInboxIds: Set<String> = [],
        preselectedInboxIds: Set<String> = [],
        onConfirm: @escaping (_ inboxIds: Set<String>) -> Void
    ) {
        _viewModel = State(initialValue: ContactsPickerViewModel(
            mode: mode,
            contactsRepository: contactsRepository,
            alreadyInChatInboxIds: alreadyInChatInboxIds,
            preselectedInboxIds: preselectedInboxIds
        ))
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            content
                .background(.colorBackgroundRaisedSecondary)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0.0) {
            ContactsSearchBar(
                query: $viewModel.searchQuery,
                placeholder: "Contacts",
                accessibilityIdentifier: "contacts-picker-search-field"
            )
            ContactsPickerSelectedPills(
                contacts: viewModel.selectedContacts,
                onRemove: handleRemove
            )
            ContactsPickerList(
                viewModel: viewModel,
                onToggle: handleToggle
            )
            ContactsPickerConfirmButton(
                title: viewModel.confirmButtonTitle,
                isEnabled: viewModel.canConfirm,
                onTap: handleConfirm
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .cancel, action: handleCancel)
        }
        ToolbarItem(placement: .principal) {
            ContactsPickerTitlePill(
                title: viewModel.pillTitle,
                subtitle: viewModel.pillSubtitle
            )
        }
    }

    // MARK: - Actions

    private func handleToggle(_ inboxId: String) {
        viewModel.toggleSelection(for: inboxId)
    }

    private func handleRemove(_ inboxId: String) {
        viewModel.deselect(inboxId: inboxId)
    }

    private func handleConfirm() {
        let ids = viewModel.selectedInboxIds
        guard !ids.isEmpty else { return }
        onConfirm(ids)
        dismiss()
    }

    private func handleCancel() {
        dismiss()
    }
}

// MARK: - Title pill

/// Elevated capsule shown in the navigation bar's principal slot. Two-line
/// layout: pill title on top ("New convo" / "Add to convo"), member-count
/// subtitle below. Replaces the standard nav title to match the design.
private struct ContactsPickerTitlePill: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 0.0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.stepX)
        .background(
            Capsule().fill(.colorBackgroundRaisedSecondary)
        )
        .overlay(
            Capsule().stroke(.colorTextTertiary.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 6.0, x: 0.0, y: 2.0)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contacts-picker-title-pill")
    }
}

// MARK: - List

private struct ContactsPickerList: View {
    @Bindable var viewModel: ContactsPickerViewModel
    let onToggle: (String) -> Void

    var body: some View {
        if viewModel.sections.isEmpty {
            emptyState
        } else {
            sectionedList
        }
    }

    @ViewBuilder
    private var sectionedList: some View {
        List {
            ForEach(viewModel.sections) { section in
                Section(header: ContactsPickerSectionHeader(title: section.title)) {
                    ForEach(section.rows) { row in
                        ContactsPickerRow(
                            row: row,
                            isSelected: viewModel.isSelected(inboxId: row.id),
                            onTap: rowTapAction(for: row)
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
    }

    private var emptyState: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .resizable()
                .scaledToFit()
                .frame(width: 48.0, height: 48.0)
                .foregroundStyle(.colorTextTertiary)
            Text("No contacts to show")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignConstants.Spacing.step6x)
    }

    private func rowTapAction(for row: ContactsPickerViewModel.Row) -> () -> Void {
        let inboxId = row.id
        let isAlreadyInChat = row.isAlreadyInChat
        return {
            guard !isAlreadyInChat else { return }
            onToggle(inboxId)
        }
    }
}

// MARK: - Section header

private struct ContactsPickerSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.colorTextSecondary)
            .textCase(nil)
            .padding(.leading, DesignConstants.Spacing.step2x)
    }
}

// MARK: - Confirm CTA

private struct ContactsPickerConfirmButton: View {
    let title: String
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        let backgroundOpacity: Double = isEnabled ? 1.0 : 0.4
        Button(action: onTap) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step6x)
                .background(
                    RoundedRectangle(cornerRadius: 32.0)
                        .fill(.colorTextPrimary.opacity(backgroundOpacity))
                )
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier("contacts-picker-confirm")
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
    }
}

// MARK: - Previews

#Preview("New conversation") {
    ContactsPickerView(
        mode: .newConversation,
        contactsRepository: MockContactsRepository(),
        onConfirm: { _ in }
    )
}

#Preview("Add to conversation") {
    ContactsPickerView(
        mode: .addToConversation(conversationId: "convo-1", conversationTitle: "The Dev Convosation"),
        contactsRepository: MockContactsRepository(),
        alreadyInChatInboxIds: [MockContactsRepository.defaultMockContacts[0].inboxId],
        onConfirm: { _ in }
    )
}

#Preview("Empty") {
    ContactsPickerView(
        mode: .newConversation,
        contactsRepository: MockContactsRepository(contacts: []),
        onConfirm: { _ in }
    )
}

#Preview("Many pills wrap") {
    let contacts: [Contact] = [
        .mock(displayName: "Alice"),
        .mock(displayName: "Bob"),
        .mock(displayName: "Carol"),
        .mock(displayName: "Daniel"),
        .mock(displayName: "Evelyn"),
        .mock(displayName: "Frederick"),
        .mock(displayName: "Genevieve"),
        .mock(displayName: "Hieronymus"),
    ]
    let preselected: Set<String> = Set(contacts.map(\.inboxId))
    return ContactsPickerView(
        mode: .newConversation,
        contactsRepository: MockContactsRepository(contacts: contacts),
        preselectedInboxIds: preselected,
        onConfirm: { _ in }
    )
}
