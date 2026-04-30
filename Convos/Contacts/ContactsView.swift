import ConvosCore
import SwiftUI

struct ContactsView: View {
    @State private var viewModel: ContactsViewModel

    init(contactsRepository: any ContactsRepositoryProtocol) {
        _viewModel = State(initialValue: ContactsViewModel(contactsRepository: contactsRepository))
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
    }

    @ViewBuilder
    private var contactList: some View {
        List {
            ForEach(viewModel.sections) { section in
                Section(header: Text(section.title)) {
                    ForEach(section.contacts) { contact in
                        NavigationLink {
                            ContactCardView(contact: contact)
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
