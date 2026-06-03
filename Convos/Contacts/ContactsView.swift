import ConvosCore
import SwiftUI

struct ContactsView: View {
    @State private var viewModel: ContactsViewModel
    @State private var presentingPicker: Bool = false
    @State private var presentingNewConvo: NewConversationViewModel?

    private let contactsRepository: any ContactsRepositoryProtocol
    private let contactsWriter: any ContactsWriterProtocol
    private let session: (any SessionManagerProtocol)?
    private let profileSettingsViewModel: ProfileSettingsViewModel
    /// Whether to render the contacts-scoped compose button. The Contacts
    /// tab hides it because the shell's shared toolbar already provides a
    /// compose button (whose `onStartConvo` opens the same contacts picker),
    /// so the tab's top bar matches Chats and Stuff exactly.
    private let showsComposeButton: Bool

    init(
        contactsRepository: any ContactsRepositoryProtocol,
        contactsWriter: any ContactsWriterProtocol = MockContactsWriter(),
        session: (any SessionManagerProtocol)? = nil,
        profileSettingsViewModel: ProfileSettingsViewModel = .shared,
        showsComposeButton: Bool = true,
        suggestedAgentsService: (any SuggestedAgentsServiceProtocol)? = nil
    ) {
        _viewModel = State(initialValue: ContactsViewModel(
            contactsRepository: contactsRepository,
            suggestedAgentsService: suggestedAgentsService
        ))
        self.contactsRepository = contactsRepository
        self.contactsWriter = contactsWriter
        self.session = session
        self.profileSettingsViewModel = profileSettingsViewModel
        self.showsComposeButton = showsComposeButton
    }

    var body: some View {
        Group {
            if viewModel.sections.isEmpty {
                emptyState
            } else {
                contactsContent
            }
        }
        .task { await viewModel.loadSuggestedAgentsIfNeeded() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.colorBackgroundRaisedSecondary
                .ignoresSafeArea()
        }
        // The nav bar is forced to inline mode with a hidden background so
        // only the toolbar items remain visible at the top and the list
        // scrolls behind it with the iOS 26 glass blur, matching the
        // `safeAreaBar` treatment applied to the search bar below.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbarContent }
        .navigationDestination(for: Contact.self) { contact in
            contactDetail(for: contact)
        }
        .sheet(isPresented: $presentingPicker) { pickerSheet }
        .sheet(item: $presentingNewConvo) { vm in
            NewConversationView(
                viewModel: vm,
                profileSettingsViewModel: profileSettingsViewModel
            )
            .background(.colorBackgroundSurfaceless)
        }
    }

    // MARK: - List

    /// Same `safeAreaBar` treatment the contacts picker and chat
    /// composer use. The search bar floats at the top with iOS 26 glass
    /// blur, and the underlying list's scroll inset is auto-adjusted so
    /// rows scroll cleanly under the bar.
    @ViewBuilder
    private var contactsContent: some View {
        contactList
            .background(.colorBackgroundRaisedSecondary)
            .safeAreaBar(edge: .top) {
                ContactsSearchBar(
                    query: $viewModel.searchQuery,
                    placeholder: "Search contacts",
                    accessibilityIdentifier: "contacts-search-field"
                )
            }
    }

    @ViewBuilder
    private var contactList: some View {
        ContactsListView(
            sections: viewModel.sections.map { section in
                ContactsListSection(
                    id: section.id,
                    title: section.title,
                    rows: section.rows
                )
            },
            rowContent: { (row: ContactsViewModel.Row) in
                contactRow(for: row)
            },
            sectionHeader: { (section: ContactsListSection<ContactsViewModel.Row>) in
                contactsSectionHeader(for: section)
            },
            listBackground: { Color.colorBackgroundRaisedSecondary }
        )
    }

    @ViewBuilder
    private func contactRow(for row: ContactsViewModel.Row) -> some View {
        NavigationLink(value: row.contact) {
            ContactRowView(contact: row.contact, subtitle: row.subtitle)
        }
        .onAppear {
            guard row.isSuggestedAgent else { return }
            let rowId = row.id
            Task { await viewModel.suggestedAgentRowAppeared(id: rowId) }
        }
    }

    @ViewBuilder
    private func contactsSectionHeader(for section: ContactsListSection<ContactsViewModel.Row>) -> some View {
        if section.id == SuggestedAgentsSection.id {
            SuggestedAgentsSectionHeader()
        } else {
            ContactsListSectionHeader(title: section.title)
        }
    }

    /// Detail pushed when a contact row is tapped. Built here (rather than
    /// inline in the row) so navigation is value-based -- the host lifts the
    /// stack path to know when a detail is on screen.
    @ViewBuilder
    private func contactDetail(for contact: Contact) -> some View {
        ContactDetailView(
            contact: contact,
            contactsWriter: contactsWriter,
            contactsRepository: contactsRepository,
            session: session,
            profileSettingsViewModel: profileSettingsViewModel,
            showsCloseButton: false
        )
    }

    private var emptyState: some View {
        ContactsEmptyStateView()
            .background(.colorBackgroundRaisedSecondary)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showsComposeButton {
            ToolbarItem(placement: .topBarTrailing) {
                let canCompose = session != nil && viewModel.contactCount > 0
                Button(action: presentPicker) {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(!canCompose)
                .accessibilityLabel("Start a new conversation from contacts")
                .accessibilityIdentifier("contacts-compose-button")
            }
        }
    }

    // MARK: - Picker sheet

    @ViewBuilder
    private var pickerSheet: some View {
        ContactsPickerView(
            mode: .newConversation,
            contactsRepository: contactsRepository,
            suggestedAgentsService: SuggestedAgentsService.live(),
            onConfirm: handlePickerConfirm
        )
    }

    // MARK: - Actions

    private func presentPicker() {
        presentingPicker = true
    }

    /// Spins up a `NewConversationViewModel` locally and presents it as a
    /// sheet from this view, so the new conversation appears in place of
    /// the picker while the App Settings sheet stack stays alive
    /// underneath. Dismissing the new-convo sheet lands the user back on
    /// the contacts list, not at the root conversations list. Mirrors the
    /// invite-cell-tap pattern (`presentingNewConversationForInvite` on
    /// `ConversationViewModel`) where the sheet is owned by the same view
    /// that hosted the picker.
    private func handlePickerConfirm(_ memberInboxIds: Set<String>, _ agentTemplateId: String?) {
        guard !memberInboxIds.isEmpty || agentTemplateId != nil, let session else { return }
        presentingNewConvo = NewConversationViewModel(
            session: session,
            mode: .newConversationWithMembers(
                initialMemberInboxIds: Array(memberInboxIds),
                agentTemplateId: agentTemplateId
            )
        )
    }
}

#Preview("With Contacts") {
    NavigationStack {
        ContactsView(contactsRepository: MockContactsRepository())
    }
}

#Preview("Empty") {
    NavigationStack {
        ContactsView(contactsRepository: MockContactsRepository(contacts: []))
    }
}
