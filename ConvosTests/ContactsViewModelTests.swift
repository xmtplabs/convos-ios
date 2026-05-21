import Combine
@testable import Convos
import ConvosCore
import XCTest

/// Coverage for `ContactsViewModel` - the view model backing the standalone
/// contacts browse screen (the contacts list reachable from app settings).
/// The picker view model has its own suite in `ContactsPickerViewModelTests`.
@MainActor
final class ContactsViewModelTests: XCTestCase {
    /// Human `inboxId`s across every section, in render order.
    private func humanInboxIds(_ viewModel: ContactsViewModel) -> [String] {
        viewModel.sections.flatMap { section in
            section.items.compactMap { item -> String? in
                guard case .human(let contact) = item else { return nil }
                return contact.inboxId
            }
        }
    }

    /// Resolved display names across every section, in render order.
    private func displayNames(_ viewModel: ContactsViewModel) -> [String] {
        viewModel.sections.flatMap { section in
            section.items.map(\.resolvedDisplayName)
        }
    }

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

<<<<<<< HEAD
        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
=======
>>>>>>> 2d0d2b7d (feat(agent-templates): capture and browse agent-template contacts)
        // Alice and the unverified agent pass through; both verified agents
        // are filtered out. Unverified agents intentionally remain visible
        // because they're not yet attested.
        XCTAssertEqual(humanInboxIds(viewModel).sorted(), [alice.inboxId, unverifiedAgent.inboxId].sorted())
    }

    /// `contactCount` drives the empty-state vs list-state branch in the
    /// `ContactsView` body and the compose button's enabled flag. It must
    /// reflect the visible count, not the raw `DBContact` count - otherwise
    /// a user whose only `DBContact` rows are verified agents would see an
    /// empty list with a non-empty count.
    func testContactCountReflectsVisibleContactsNotRawCount() {
        let assistant = Contact.mock(
            displayName: "Convos Assistant",
            agentVerification: .verified(.convos)
        )
        let repo = MockContactsRepository(contacts: [assistant])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        XCTAssertEqual(viewModel.contactCount, 0,
                       "Verified-agent DBContact rows should not count toward the visible total")
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
