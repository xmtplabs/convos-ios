import ConvosCore
import SwiftUI

struct ContactsView: View {
    @State private var viewModel: ContactsViewModel
    @State private var presentingPicker: Bool = false

    private let contactsRepository: any ContactsRepositoryProtocol
    private let contactsWriter: any ContactsWriterProtocol
    private let session: (any SessionManagerProtocol)?

    init(
        contactsRepository: any ContactsRepositoryProtocol,
        contactsWriter: any ContactsWriterProtocol = MockContactsWriter(),
        session: (any SessionManagerProtocol)? = nil
    ) {
        _viewModel = State(initialValue: ContactsViewModel(contactsRepository: contactsRepository))
        self.contactsRepository = contactsRepository
        self.contactsWriter = contactsWriter
        self.session = session
    }

    var body: some View {
        Group {
            if viewModel.contactCount == 0 {
                emptyState
            } else {
                contactList
            }
        }
        .navigationTitle("Contacts")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .sheet(isPresented: $presentingPicker) { pickerSheet }
    }

    // MARK: - List

    @ViewBuilder
    private var contactList: some View {
        List {
            ForEach(viewModel.sections) { section in
                Section(header: Text(section.title)) {
                    ForEach(section.contacts) { contact in
                        NavigationLink {
                            ContactCardView(
                                contact: contact,
                                contactsWriter: contactsWriter,
                                contactsRepository: contactsRepository,
                                session: session
                            )
                        } label: {
                            ContactRowView(contact: contact)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
    }

    private var emptyState: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "person.2.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(.colorTextTertiary)
            Text("No contacts yet")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Text("People you message in groups will show up here.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.colorTextSecondary)
                .padding(.horizontal, DesignConstants.Spacing.step6x)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            onConfirm: handlePickerConfirm
        )
    }

    // MARK: - Actions

    private func presentPicker() {
        presentingPicker = true
    }

    /// The picker doesn't create the conversation itself; it just hands
    /// the chosen inbox IDs to the conversations layer, which spins up a
    /// `NewConversationViewModel` driven by
    /// `.newConversationWithMembers(...)`. That view model presents the
    /// placeholder UI instantly and folds `addMembers` into the state
    /// machine's create sequence so `.ready` already includes them.
    private func handlePickerConfirm(_ inboxIds: Set<String>) {
        guard !inboxIds.isEmpty else { return }
        let ids = Array(inboxIds)
        NotificationCenter.default.post(
            name: .contactsRequestedNewConversation,
            object: nil,
            userInfo: ["inboxIds": ids]
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
