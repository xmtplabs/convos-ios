import ConvosCore
import SwiftUI

// MARK: - Module overview
//
// `ContactsPickerView` is the canonical multi-select contact picker.
// It is invoked from four entry points, parameterized by `ContactsPickerMode`:
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
//   4. Primary compose flow from the home shell (`MainTabView` ->
//      `ComposeFlowView`, driven by
//      `ConversationsViewModel.presentingComposeFlow`), `mode: .compose`
//      with `embedsNavigationStack: false` so the picker is the root of the
//      compose sheet's own `NavigationStack` and pushes the drafted
//      conversation on confirm instead of presenting another sheet.
//
// Mirrors `ContactDetailMode`'s "one component, two-or-more entry points"
// pattern. The view itself is presentation-only; callers own the side
// effect on confirm by passing in `onConfirm`.

/// Multi-select contact picker. See module-overview comment above for
/// entry-point mapping and the role each mode plays.
struct ContactsPickerView: View {
    @State private var viewModel: ContactsPickerViewModel
    @State private var presentingAgentInfo: Bool = false
    /// Set by the "One agent, many convos" sheet's "Got it" button so the
    /// sheet's `onDismiss` knows to proceed with creation (vs a cancel).
    @State private var agentInfoConfirmed: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction

    /// `memberInboxIds` are the selected humans; `agentTemplateIds` are the
    /// templates of the selected agents (one fresh instance is spawned per
    /// id), empty when no agent was picked.
    let onConfirm: (_ memberInboxIds: Set<String>, _ agentTemplateIds: [String]) -> Void
    /// Optional source conversation that informs the indicator pill's
    /// emoji avatar. For the new-convo flow callers can pass the current
    /// draft so the picker reflects whatever emoji the convo will inherit;
    /// for the add-to-conversation flow callers can pass the destination
    /// conversation. Nil shows a stable default avatar.
    let pillConversation: Conversation?
    /// When `true` (the default) the picker wraps its content in its own
    /// `NavigationStack`, suitable for being presented standalone as a sheet.
    /// The compose flow passes `false` so the picker is the root of the host
    /// navigation stack and pushes the new conversation instead.
    let embedsNavigationStack: Bool

    init(
        mode: ContactsPickerMode,
        contactsRepository: any ContactsRepositoryProtocol,
        alreadyInChatInboxIds: Set<String> = [],
        preselectedInboxIds: Set<String> = [],
        pillConversation: Conversation? = nil,
        embedsNavigationStack: Bool = true,
        suggestedAgentsService: (any SuggestedAgentsServiceProtocol)? = nil,
        onConfirm: @escaping (_ memberInboxIds: Set<String>, _ agentTemplateIds: [String]) -> Void
    ) {
        _viewModel = State(initialValue: ContactsPickerViewModel(
            mode: mode,
            contactsRepository: contactsRepository,
            alreadyInChatInboxIds: alreadyInChatInboxIds,
            preselectedInboxIds: preselectedInboxIds,
            suggestedAgentsService: suggestedAgentsService
        ))
        self.pillConversation = pillConversation
        self.embedsNavigationStack = embedsNavigationStack
        self.onConfirm = onConfirm
    }

    var body: some View {
        pickerBody
            .selfSizingSheet(
                isPresented: $presentingAgentInfo,
                onDismiss: handleAgentInfoDismiss,
                content: { OneAgentManyConvosInfoSheet(onConfirm: { agentInfoConfirmed = true }) }
            )
    }

    @ViewBuilder
    private var pickerBody: some View {
        if embedsNavigationStack {
            NavigationStack { stackContent }
        } else {
            stackContent
        }
    }

    @ViewBuilder
    private var stackContent: some View {
        content
            .background(.colorBackgroundRaisedSecondary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
    }

    private func handleAgentInfoDismiss() {
        guard agentInfoConfirmed else { return }
        agentInfoConfirmed = false
        performConfirm()
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
                    accessibilityIdentifier: "contacts-picker-search-field",
                    filter: $viewModel.filter
                )
                ContactsPickerSelectedPills(
                    contacts: viewModel.selectedContacts,
                    onRemove: handleRemove
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

    private func handleToggle(_ inboxId: String) {
        viewModel.toggleSelection(for: inboxId)
    }

    private func handleRemove(_ inboxId: String) {
        viewModel.deselect(inboxId: inboxId)
    }

    private func handleConfirm() {
        guard viewModel.canConfirm else { return }
        // Starting a conversation that includes an agent shows the
        // "One agent, many convos" sheet as a confirmation step first; its
        // "Got it" button proceeds via `performConfirm`. Human-only
        // selections create the conversation immediately.
        if !viewModel.selectedAgentTemplateIds.isEmpty {
            presentingAgentInfo = true
        } else {
            performConfirm()
        }
    }

    private func performConfirm() {
        // Split the selection: agents are spawned by template, not added
        // as members, so they're excluded from the member ids.
        let agentTemplateIds = viewModel.selectedAgentTemplateIds
        let memberIds = viewModel.selectedInboxIds.subtracting(viewModel.selectedAgentInboxIds)
        onConfirm(memberIds, agentTemplateIds)
        // Compose hosts the picker in its own navigation stack and pushes
        // the new conversation, so it must not dismiss here.
        if !viewModel.mode.isCompose {
            dismiss()
        }
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
    let onToggle: (String) -> Void

    var body: some View {
        content
            .task { await viewModel.loadSuggestedAgentsIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.sections.isEmpty {
            if viewModel.isLoadingSuggestedAgents {
                loadingState
            } else if viewModel.isFiltering {
                filteredEmptyState
            } else {
                emptyState
            }
        } else {
            list
        }
    }

    private var list: some View {
        ContactsListView(
            sections: viewModel.sections.map { section in
                ContactsListSection(
                    id: section.id,
                    title: section.title,
                    rows: section.rows
                )
            },
            rowContent: { (row: ContactsPickerViewModel.Row) in
                rowView(for: row)
            },
            sectionHeader: { (section: ContactsListSection<ContactsPickerViewModel.Row>) in
                sectionHeader(for: section)
            },
            listBackground: { Color.colorBackgroundRaisedSecondary }
        )
    }

    @ViewBuilder
    private func rowView(for row: ContactsPickerViewModel.Row) -> some View {
        ContactsPickerRow(
            row: row,
            isSelected: viewModel.isSelected(inboxId: row.id),
            onTap: rowTapAction(for: row)
        )
        .onAppear {
            guard row.isSuggestedAgent else { return }
            let rowId = row.id
            Task { await viewModel.suggestedAgentRowAppeared(id: rowId) }
        }
    }

    @ViewBuilder
    private func sectionHeader(for section: ContactsListSection<ContactsPickerViewModel.Row>) -> some View {
        if section.id == SuggestedAgentsSection.id {
            SuggestedAgentsSectionHeader()
        } else {
            ContactsListSectionHeader(title: section.title)
        }
    }

    private var loadingState: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignConstants.Spacing.step6x)
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

    private var filteredEmptyState: some View {
        VStack {
            Spacer()
            FilteredEmptyStateView(
                message: "No contacts",
                accessibilityLabel: "Show all contacts"
            ) {
                viewModel.clearFilters()
            }
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        onConfirm: { _, _ in }
    )
}

#Preview("Suggested agents") {
    let suggested: [SuggestedAgent] = [
        .mock(templateId: "trip", name: "Trip", description: "Travel agent", emoji: "🧳"),
        .mock(templateId: "champ", name: "Champ", description: "Team manager", emoji: "🏆"),
        .mock(templateId: "chef", name: "Chef", description: "Meal and nutrition partner", emoji: "🍽️"),
        .mock(templateId: "scoop", name: "Scoop", description: "Neighborhood expert", emoji: "🗞️"),
    ]
    return ContactsPickerView(
        mode: .newConversation,
        contactsRepository: MockContactsRepository(),
        suggestedAgentsService: MockSuggestedAgentsService(agents: suggested),
        onConfirm: { _, _ in }
    )
}

#Preview("Suggested agents, no contacts") {
    let suggested: [SuggestedAgent] = [
        .mock(templateId: "trip", name: "Trip", description: "Travel agent", emoji: "🧳"),
        .mock(templateId: "champ", name: "Champ", description: "Team manager", emoji: "🏆"),
        .mock(templateId: "chef", name: "Chef", description: "Meal and nutrition partner", emoji: "🍽️"),
    ]
    return ContactsPickerView(
        mode: .newConversation,
        contactsRepository: MockContactsRepository(contacts: []),
        suggestedAgentsService: MockSuggestedAgentsService(agents: suggested),
        onConfirm: { _, _ in }
    )
}

#Preview("Add to conversation") {
    ContactsPickerView(
        mode: .addToConversation(conversationId: "convo-1", conversationTitle: "The Dev Convosation"),
        contactsRepository: MockContactsRepository(),
        alreadyInChatInboxIds: [MockContactsRepository.defaultMockContacts[0].inboxId],
        onConfirm: { _, _ in }
    )
}

#Preview("Empty") {
    ContactsPickerView(
        mode: .newConversation,
        contactsRepository: MockContactsRepository(contacts: []),
        onConfirm: { _, _ in }
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
        onConfirm: { _, _ in }
    )
}
