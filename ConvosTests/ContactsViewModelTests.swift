import Combine
@testable import Convos
import ConvosCore
import XCTest

/// Coverage for `ContactsViewModel` - the view model backing the standalone
/// contacts browse screen (the contacts list reachable from app settings).
/// The picker view model has its own suite in `ContactsPickerViewModelTests`.
@MainActor
final class ContactsViewModelTests: XCTestCase {
    // MARK: - Verified-agent filter

    /// Verified-agent contacts stay in `DBContact` so chat-side surfaces
    /// (member rows, system messages, the contact card opened from a chat
    /// member tap) can still resolve them. They are filtered out of the
    /// human-facing contact browser. Regression guard: if the predicate is
    /// removed, the contacts list would show every Convos / OAuth-attested
    /// agent alongside real people.
    func testSectionsExcludeVerifiedAgents() {
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
        // Alice and the unverified agent pass through; both verified agents
        // are filtered out. Unverified agents intentionally remain visible
        // because they're not yet attested.
        XCTAssertEqual(allIds.sorted(), [alice.inboxId, unverifiedAgent.inboxId].sorted())
    }

    /// `contactCount` drives the empty-state vs list-state branch in the
    /// `ContactsView` body and the compose button's enabled flag. It must
    /// reflect the human-visible count, not the raw count - otherwise a
    /// user whose contacts are all agents would see an empty list with a
    /// non-empty count (no empty-state CTA, enabled compose button).
    func testContactCountReflectsVisibleContactsNotRawCount() {
        let assistant = Contact.mock(
            displayName: "Convos Assistant",
            agentVerification: .verified(.convos)
        )
        let repo = MockContactsRepository(contacts: [assistant])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        XCTAssertEqual(viewModel.contactCount, 0,
                       "Agent-only contacts should not count toward the visible total")
        XCTAssertTrue(viewModel.sections.isEmpty)
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

    func testSearchAndVerifiedAgentFilterComposeCorrectly() {
        let alice = Contact.mock(displayName: "Alice")
        let aliceAssistant = Contact.mock(
            displayName: "Alice Assistant",
            agentVerification: .verified(.convos)
        )
        let bob = Contact.mock(displayName: "Bob")
        let repo = MockContactsRepository(contacts: [alice, aliceAssistant, bob])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        // Searching "alice" must not surface the verified Alice Assistant -
        // the agent filter precedes the search filter in the pipeline.
        viewModel.searchQuery = "alice"
        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds, [alice.inboxId])
    }
}
