import ConvosCore
import SwiftUI

// MARK: - Module overview
//
// `ContactsPickerView` is the canonical multi-select contact picker.
// It is invoked from three entry points, parameterized by `ContactsPickerMode`:
//
//   1. Compose toolbar on the contacts list (`ContactsView` toolbar `+`),
//      `mode: .newConversation`. Confirm builds a
//      `NewConversationViewModel(mode: .newConversationWithMembers(...))`
//      and presents it as a sheet from `ContactsView` itself, in place of
//      the picker, so the App Settings sheet stack stays alive.
//   2. Send-a-message CTA on the contact card (`ContactDetailView`, either
//      standalone or scoped), `mode: .newConversation` with
//      `preselectedInboxIds: [contact.inboxId]`. Confirm presents the
//      new-convo sheet from `ContactDetailView` itself using the same
//      pattern, so whatever hosts the card (App Settings stack or a chat)
//      stays alive underneath.
//   3. Add from Contacts in the chat plus-menu (`ConversationView` ->
//      `AddToConversationMenu.onAddFromContacts`), `mode:
//      .addToConversation(...)` with the conversation's existing members
//      passed as `alreadyInChatInboxIds`. Confirm calls
//      `ConversationViewModel.addMembersFromContacts(_:)`.
//
// Mirrors `ContactDetailMode`'s "one component, two-or-more entry points"
// pattern. The view itself is presentation-only; callers own the side
// effect on confirm by passing in `onConfirm`.

/// Multi-select contact picker. See module-overview comment above for
/// entry-point mapping and the role each mode plays.
struct ContactsPickerView: View {
    @State private var viewModel: ContactsPickerViewModel
    @Environment(\.dismiss) private var dismiss: DismissAction

    /// Confirm callback receives the full heterogeneous selection. Call
    /// sites split into humans (`.inboxId`) and agent templates
    /// (`.templateId`) and route each to their dispatch path.
    let onConfirm: (_ selection: Set<ContactsPickerViewModel.Selection>) -> Void
    /// Optional source conversation that informs the indicator pill's
    /// emoji avatar. For the new-convo flow callers can pass the current
    /// draft so the picker reflects whatever emoji the convo will inherit;
    /// for the add-to-conversation flow callers can pass the destination
    /// conversation. Nil shows a stable default avatar.
    let pillConversation: Conversation?
    /// When `true` (the default) the picker wraps its content in its own
    /// `NavigationStack`, suitable for being presented standalone as a
    /// sheet. The Compose flow sets this to `false` so the picker is the
    /// root of the host's stack and can push the new-conversation view onto
    /// it instead of dismissing.
    let embedsNavigationStack: Bool

    init(
        mode: ContactsPickerMode,
        contactsRepository: any ContactsRepositoryProtocol,
        agentTemplateContactsRepository: any AgentTemplateContactsRepositoryProtocol
            = MockAgentTemplateContactsRepository(contacts: []),
        alreadyInChatInboxIds: Set<String> = [],
        preselectedInboxIds: Set<String> = [],
        pillConversation: Conversation? = nil,
        embedsNavigationStack: Bool = true,
        onConfirm: @escaping (_ selection: Set<ContactsPickerViewModel.Selection>) -> Void
    ) {
        _viewModel = State(initialValue: ContactsPickerViewModel(
            mode: mode,
            contactsRepository: contactsRepository,
            agentTemplateContactsRepository: agentTemplateContactsRepository,
            alreadyInChatInboxIds: alreadyInChatInboxIds,
            preselectedInboxIds: preselectedInboxIds
        ))
        self.pillConversation = pillConversation
        self.embedsNavigationStack = embedsNavigationStack
        self.onConfirm = onConfirm
    }

    var body: some View {
        if embedsNavigationStack {
            NavigationStack { pickerContent }
        } else {
            pickerContent
        }
    }

    private var pickerContent: some View {
        content
            .background(.colorBackgroundRaisedSecondary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
    }

    /// The list takes the full sheet and scrolls behind the toolbar
    /// pill, the search bar / selected pills (top), and the continue
    /// button (bottom). `safeAreaBar` is the same modifier
    /// `MessagesView` uses for the chat composer - it floats the bar
    /// view at the edge with glass blur and auto-adjusts the
    /// scrollable child's content inset so rows still scroll past it.
    @ViewBuilder
    private var content: some View {
        ContactsPickerList(
            viewModel: viewModel,
            onToggle: handleToggle
        )
        .safeAreaBar(edge: .top) {
            VStack(spacing: 0.0) {
                ContactsSearchBar(
                    query: $viewModel.searchQuery,
                    placeholder: "Contacts",
                    accessibilityIdentifier: "contacts-picker-search-field"
                )
                ContactsPickerSelectedPills(
                    humans: viewModel.selectedContacts,
                    agentTemplates: viewModel.selectedAgentContacts,
                    onRemoveHuman: handleRemoveHuman,
                    onRemoveAgentTemplate: handleRemoveAgentTemplate
                )
            }
        }
        .safeAreaBar(edge: .bottom) {
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
            ContactsPickerIndicatorPill(
                conversation: pillConversation,
                title: viewModel.pillTitle,
                subtitle: viewModel.pillSubtitle
            )
        }
    }

    // MARK: - Actions

    private func handleToggle(_ selection: ContactsPickerViewModel.Selection) {
        viewModel.toggleSelection(selection)
    }

    private func handleRemoveHuman(_ inboxId: String) {
        viewModel.deselect(.human(inboxId: inboxId))
    }

    private func handleRemoveAgentTemplate(_ templateId: String) {
        viewModel.deselect(.agentTemplate(templateId: templateId))
    }

    private func handleConfirm() {
        let selection = viewModel.selected
        if case .compose = viewModel.mode {
            // Compose: Skip/Continue proceeds even with no selection, and the
            // host pushes the new-conversation view onto the stack, so the
            // picker stays put as the root rather than dismissing itself.
            onConfirm(selection)
            return
        }
        guard !selection.isEmpty else { return }
        onConfirm(selection)
        dismiss()
    }

    private func handleCancel() {
        dismiss()
    }
}

// MARK: - Indicator pill

/// Conversation-indicator-style pill rendered at the top of the picker.
/// Mirrors the `ConversationToolbarButton` look used by `ConversationIndicator`
/// (avatar + title + subtitle inside a glass capsule) so the picker reads
/// as the entry point to a forthcoming conversation. The avatar peeks at
/// the supplied source conversation's emoji; when no conversation is
/// supplied a stable default emoji is rendered as the placeholder.
private struct ContactsPickerIndicatorPill: View {
    let conversation: Conversation?
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 0.0) {
            avatar
                .frame(width: 36.0, height: 36.0)

            VStack(alignment: .leading, spacing: 0.0) {
                Text(title)
                    .lineLimit(1)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.colorTextPrimary)
                    .fixedSize()
                Text(subtitle)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
        }
        .padding(DesignConstants.Spacing.step2x)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityIdentifier("contacts-picker-indicator-pill")
    }

    @ViewBuilder
    private var avatar: some View {
        if let conversation {
            ConversationAvatarView(conversation: conversation, conversationImage: nil)
        } else {
            placeholderAvatar
        }
    }

    /// `EmojiAvatarView`'s default `.colorFillMinimal` fill (#FAFAFA) is
    /// indistinguishable from the surrounding glass capsule, so the emoji
    /// reads as floating with no avatar ring. Paint the placeholder with
    /// the page background fill plus a thin tertiary stroke so the circle
    /// stays visible against the glass material.
    private var placeholderAvatar: some View {
        Circle()
            .fill(.colorBackgroundRaisedSecondary)
            .overlay(
                Circle().stroke(.colorTextTertiary.opacity(0.2), lineWidth: 0.5)
            )
            .overlay(
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    Text(Constant.placeholderEmoji)
                        .font(.system(size: side * 0.43, weight: .semibold, design: .rounded))
                        .frame(width: side, height: side)
                }
            )
    }

    private enum Constant {
        /// Used when the picker is opened without a source conversation
        /// (e.g. starting a brand-new convo from the contacts list).
        /// Picked to read as "a new conversation about to happen".
        static let placeholderEmoji: String = "✨"
    }
}

// MARK: - List

private struct ContactsPickerList: View {
    @Bindable var viewModel: ContactsPickerViewModel
    let onToggle: (ContactsPickerViewModel.Selection) -> Void

    var body: some View {
        if viewModel.sections.isEmpty {
            emptyState
        } else {
            ContactsListView(
                sections: viewModel.sections.map { section in
                    ContactsListSection(
                        id: section.id,
                        title: section.title,
                        rows: section.rows
                    )
                },
                rowContent: { (row: ContactsPickerViewModel.Row) in
                    ContactsPickerRow(
                        row: row,
                        isSelected: viewModel.isSelected(row.selection),
                        onTap: rowTapAction(for: row)
                    )
                },
                listBackground: { Color.colorBackgroundRaisedSecondary }
            )
        }
    }

    private var emptyState: some View {
        ContactsEmptyStateView()
    }

    private func rowTapAction(for row: ContactsPickerViewModel.Row) -> () -> Void {
        let selection = row.selection
        let isAlreadyInChat = row.isAlreadyInChat
        return {
            guard !isAlreadyInChat else { return }
            onToggle(selection)
        }
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
                .font(.body)
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

#Preview("Humans + agents") {
    let humans: [Contact] = [
        .mock(displayName: "Alice"),
        .mock(displayName: "Bob"),
    ]
    let agents: [AgentTemplateContact] = [
        .mock(displayName: "Tifoso", emoji: "🚴", descriptionText: "Pro cycling expert"),
        .mock(displayName: "Trip Planner", emoji: "🗺️", descriptionText: "Plans your next adventure"),
    ]
    return ContactsPickerView(
        mode: .newConversation,
        contactsRepository: MockContactsRepository(contacts: humans),
        agentTemplateContactsRepository: MockAgentTemplateContactsRepository(contacts: agents),
        onConfirm: { _ in }
    )
}
