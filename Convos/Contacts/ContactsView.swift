import ConvosCore
import SwiftUI

struct ContactsView: View {
    @State private var viewModel: ContactsViewModel
    @State private var presentingPicker: Bool = false
    @State private var presentingNewConvo: NewConversationViewModel?

    private let contactsRepository: any ContactsRepositoryProtocol
    private let contactsWriter: any ContactsWriterProtocol
    private let agentTemplateContactsRepository: any AgentTemplateContactsRepositoryProtocol
    private let agentTemplateContactsWriter: any AgentTemplateContactsWriterProtocol
    private let session: (any SessionManagerProtocol)?
    private let profileSettingsViewModel: ProfileSettingsViewModel

    init(
        contactsRepository: any ContactsRepositoryProtocol,
        contactsWriter: any ContactsWriterProtocol = MockContactsWriter(),
        session: (any SessionManagerProtocol)? = nil,
        profileSettingsViewModel: ProfileSettingsViewModel = .shared,
        agentTemplateContactsRepository: any AgentTemplateContactsRepositoryProtocol = MockAgentTemplateContactsRepository(),
        agentTemplateContactsWriter: any AgentTemplateContactsWriterProtocol = MockAgentTemplateContactsWriter()
    ) {
        _viewModel = State(initialValue: ContactsViewModel(
            contactsRepository: contactsRepository,
            agentTemplateContactsRepository: agentTemplateContactsRepository
        ))
        self.contactsRepository = contactsRepository
        self.contactsWriter = contactsWriter
        self.agentTemplateContactsRepository = agentTemplateContactsRepository
        self.agentTemplateContactsWriter = agentTemplateContactsWriter
        self.session = session
        self.profileSettingsViewModel = profileSettingsViewModel
    }

    var body: some View {
        Group {
            if viewModel.contactCount == 0 {
                emptyState
            } else {
                contactsContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.colorBackgroundRaisedSecondary
                .ignoresSafeArea()
        }
        // The system `.largeTitle` doesn't transition cleanly during the
        // navigation pop / search keyboard appearance, so render the
        // header as an inline `Text` above the search bar instead. The
        // nav bar is forced to inline mode so only the back / compose
        // toolbar items remain visible at the top. The bar background
        // is hidden so the list scrolls behind it with the iOS 26 glass
        // blur, matching the `safeAreaBar` treatment we apply to the
        // title + search bar below.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbarContent }
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
    /// composer use. The title + search bar float at the top with iOS 26
    /// glass blur, and the underlying list's scroll inset is
    /// auto-adjusted so rows scroll cleanly under the bar.
    @ViewBuilder
    private var contactsContent: some View {
        contactList
            .background(.colorBackgroundRaisedSecondary)
            .safeAreaBar(edge: .top) {
                VStack(spacing: 0.0) {
                    titleLabel
                    ContactsSearchBar(
                        query: $viewModel.searchQuery,
                        placeholder: "Search",
                        accessibilityIdentifier: "contacts-search-field"
                    )
                }
            }
    }

    /// Custom large-title replacement (see comment on `body`). Sized
    /// per the figma `large/ios` style: SF Pro Bold 40pt with -1pt
    /// tracking, anchored at 25pt from the leading edge so it lines up
    /// with the contacts rows below.
    private var titleLabel: some View {
        Text("Contacts")
            .font(.system(size: 40.0, weight: .bold))
            .tracking(-1.0)
            .foregroundStyle(.colorTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 25.0)
            .padding(.top, DesignConstants.Spacing.step2x)
            .accessibilityAddTraits(.isHeader)
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
                rowDestination(for: row)
            },
            listBackground: { Color.colorBackgroundRaisedSecondary }
        )
    }

    /// Renders one browse row. A human row pushes `ContactDetailView`; an
    /// agent-template row pushes the sibling `AgentTemplateContactCardView`.
    @ViewBuilder
    private func rowDestination(for row: ContactsViewModel.Row) -> some View {
        switch row.kind {
        case .human(let contact):
            NavigationLink {
                ContactDetailView(
                    contact: contact,
                    contactsWriter: contactsWriter,
                    contactsRepository: contactsRepository,
                    agentTemplateContactsRepository: agentTemplateContactsRepository,
                    session: session,
                    profileSettingsViewModel: profileSettingsViewModel,
                    showsCloseButton: false
                )
            } label: {
                ContactRowView(contact: contact, subtitle: row.subtitle)
            }
        case .agentTemplate(let agent):
            NavigationLink {
                AgentTemplateContactCardView(
                    agentTemplateContact: agent,
                    agentTemplateContactsWriter: agentTemplateContactsWriter,
                    session: session,
                    profileSettingsViewModel: profileSettingsViewModel
                )
            } label: {
                AgentTemplateContactRowView(agentTemplateContact: agent)
            }
        }
    }

    private var emptyState: some View {
        ContactsEmptyStateView()
            .background(.colorBackgroundRaisedSecondary)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

    // MARK: - Picker sheet

    @ViewBuilder
    private var pickerSheet: some View {
        ContactsPickerView(
            mode: .newConversation,
            contactsRepository: contactsRepository,
            agentTemplateContactsRepository: agentTemplateContactsRepository,
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
    /// underneath.
    private func handlePickerConfirm(_ selection: Set<ContactsPickerViewModel.Selection>) {
        guard !selection.isEmpty, let session else { return }
        let inboxIds: [String] = selection.compactMap(\.inboxId)
        let templateIds: [String] = selection.compactMap(\.templateId)
        presentingNewConvo = NewConversationViewModel(
            session: session,
            mode: .newConversationWithMembers(
                initialMemberInboxIds: inboxIds,
                initialAgentTemplateIds: templateIds
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
        ContactsView(
            contactsRepository: MockContactsRepository(contacts: []),
            agentTemplateContactsRepository: MockAgentTemplateContactsRepository(contacts: [])
        )
    }
}
