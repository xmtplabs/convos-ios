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

    /// Only template-backed agents appear in the browse list (tagged with
    /// the trailing Agent pill). Humans always show; agents without a
    /// template id - legacy verified assistants and unverified agents -
    /// stay in `DBContact` for chat-side resolution but are hidden here.
    func testSectionsShowOnlyTemplateBackedAgents() {
        let alice = Contact.mock(displayName: "Alice")
        let coffeeAgent = Contact.mock(
            displayName: "Americano",
            agentVerification: .verified(.convos),
            agentTemplateId: "tmpl-coffee"
        )
        let legacyAssistant = Contact.mock(
            displayName: "Legacy Assistant",
            agentVerification: .verified(.convos)
        )
        let unverifiedAgent = Contact.mock(
            displayName: "Unverified Bot",
            agentVerification: .unverified
        )
        let repo = MockContactsRepository(contacts: [alice, coffeeAgent, legacyAssistant, unverifiedAgent])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        // Human + template-backed agent show; template-less agents hidden.
        XCTAssertEqual(allIds.sorted(), [alice.inboxId, coffeeAgent.inboxId].sorted())
    }

    /// `contactCount` drives the empty-state vs list-state branch in the
    /// `ContactsView` body and the compose button's enabled flag. It counts
    /// only browsable rows - humans and template-backed agents - so a
    /// template-less agent does not inflate the total.
    func testContactCountCountsBrowsableRowsOnly() {
        let alice = Contact.mock(displayName: "Alice")
        let coffeeAgent = Contact.mock(
            displayName: "Americano",
            agentVerification: .verified(.convos),
            agentTemplateId: "tmpl-coffee"
        )
        let legacyAssistant = Contact.mock(
            displayName: "Legacy Assistant",
            agentVerification: .verified(.convos)
        )
        let repo = MockContactsRepository(contacts: [alice, coffeeAgent, legacyAssistant])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        XCTAssertEqual(viewModel.contactCount, 2)
        XCTAssertEqual(viewModel.sections.flatMap { $0.rows }.count, 2)
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

    func testSearchMatchesHumansAndTemplateAgentsAlike() {
        let alice = Contact.mock(displayName: "Alice")
        let aliceAssistant = Contact.mock(
            displayName: "Alice Assistant",
            agentVerification: .verified(.convos),
            agentTemplateId: "tmpl-alice"
        )
        let bob = Contact.mock(displayName: "Bob")
        let repo = MockContactsRepository(contacts: [alice, aliceAssistant, bob])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        // Search spans template-backed agents too: both Alice and the
        // (template-backed) Alice Assistant match "alice"; Bob does not.
        viewModel.searchQuery = "alice"
        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds.sorted(), [alice.inboxId, aliceAssistant.inboxId].sorted())
    }
}
