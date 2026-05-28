import Combine
@testable import Convos
import ConvosCore
import XCTest

/// Coverage for `ContactsViewModel` - the view model backing the standalone
/// contacts browse screen (the contacts list reachable from app settings).
/// The picker view model has its own suite in `ContactsPickerViewModelTests`.
@MainActor
final class ContactsViewModelTests: XCTestCase {
    // MARK: - Agents in the browse list

    /// Verified agents appear in the browse list alongside humans (tagged
    /// with the trailing Agent pill on their row). Regression guard: if the
    /// browse list re-introduces an agent filter, agents the user shares a
    /// conversation with would vanish from contacts.
    func testSectionsIncludeVerifiedAgents() {
        let alice = Contact.mock(displayName: "Alice")
        let assistant = Contact.mock(
            displayName: "Convos Assistant",
            agentVerification: .verified(.convos)
        )
        let oauthAgent = Contact.mock(
            displayName: "OAuth Bot",
            agentVerification: .verified(.userOAuth)
        )
        let unverifiedAgent = Contact.mock(
            displayName: "Unverified Bot",
            agentVerification: .unverified
        )
        let repo = MockContactsRepository(contacts: [alice, assistant, oauthAgent, unverifiedAgent])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(
            allIds.sorted(),
            [alice.inboxId, assistant.inboxId, oauthAgent.inboxId, unverifiedAgent.inboxId].sorted()
        )
    }

    /// `contactCount` drives the empty-state vs list-state branch in the
    /// `ContactsView` body and the compose button's enabled flag. It now
    /// counts agents too, since they appear in the list.
    func testContactCountIncludesAgents() {
        let assistant = Contact.mock(
            displayName: "Convos Assistant",
            agentVerification: .verified(.convos)
        )
        let repo = MockContactsRepository(contacts: [assistant])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        XCTAssertEqual(viewModel.contactCount, 1)
        XCTAssertFalse(viewModel.sections.isEmpty)
    }

    // MARK: - Search

    func testSearchQueryFiltersResultsCaseInsensitively() {
        let alice = Contact.mock(displayName: "Alice")
        let bob = Contact.mock(displayName: "Bob")
        let charlie = Contact.mock(displayName: "Charlie")
        let repo = MockContactsRepository(contacts: [alice, bob, charlie])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        viewModel.searchQuery = "ALI"
        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds, [alice.inboxId])
    }

    func testSearchMatchesHumansAndAgentsAlike() {
        let alice = Contact.mock(displayName: "Alice")
        let aliceAssistant = Contact.mock(
            displayName: "Alice Assistant",
            agentVerification: .verified(.convos)
        )
        let bob = Contact.mock(displayName: "Bob")
        let repo = MockContactsRepository(contacts: [alice, aliceAssistant, bob])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        // Search now spans agents too: both Alice and the Alice Assistant
        // match "alice"; Bob does not.
        viewModel.searchQuery = "alice"
        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds.sorted(), [alice.inboxId, aliceAssistant.inboxId].sorted())
    }
}
