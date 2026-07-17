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

    // MARK: - Filtered empty state

    /// `isFiltering` distinguishes "nothing matched the search/filter" from
    /// "no contacts at all", so the view keeps the search bar and shows the
    /// "Show all" empty state instead of the onboarding empty state.
    func testIsFilteringReflectsSearchAndAudienceFilter() {
        let repo = MockContactsRepository(contacts: [.mock(displayName: "Alice")])
        let viewModel = ContactsViewModel(contactsRepository: repo)

        XCTAssertFalse(viewModel.isFiltering)

        viewModel.searchQuery = "  "
        XCTAssertFalse(viewModel.isFiltering, "whitespace-only query is not filtering")

        viewModel.searchQuery = "zzz"
        XCTAssertTrue(viewModel.isFiltering)

        viewModel.searchQuery = ""
        XCTAssertFalse(viewModel.isFiltering)

        viewModel.filter = .agents
        XCTAssertTrue(viewModel.isFiltering)
    }

    /// "Show all" clears both the text search and the audience filter, so the
    /// full list comes back and `isFiltering` reads false again.
    func testClearFiltersRestoresFullList() {
        let alice = Contact.mock(displayName: "Alice")
        let bob = Contact.mock(displayName: "Bob")
        let repo = MockContactsRepository(contacts: [alice, bob])
        let viewModel = ContactsViewModel(contactsRepository: repo)

        viewModel.searchQuery = "zzz"
        XCTAssertTrue(viewModel.sections.isEmpty)
        XCTAssertTrue(viewModel.isFiltering)

        viewModel.clearFilters()

        XCTAssertFalse(viewModel.isFiltering)
        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds.sorted(), [alice.inboxId, bob.inboxId].sorted())
    }

    // MARK: - Show blocked

    /// Default state hides blocked contacts; the user opts back in via the
    /// `showBlocked` toggle.
    func testBlockedContactsHiddenByDefault() {
        let alice = Contact.mock(displayName: "Alice")
        let blockedBob = Contact.mock(displayName: "Bob", isBlocked: true)
        let repo = MockContactsRepository(contacts: [alice, blockedBob])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds, [alice.inboxId])
    }

    func testShowBlockedToggleRevealsBlockedRows() {
        let alice = Contact.mock(displayName: "Alice")
        let blockedBob = Contact.mock(displayName: "Bob", isBlocked: true)
        let repo = MockContactsRepository(contacts: [alice, blockedBob])

        let viewModel = ContactsViewModel(contactsRepository: repo)
        viewModel.showBlocked = true

        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds.sorted(), [alice.inboxId, blockedBob.inboxId].sorted())
    }

    /// `contactCount` is the unfiltered count of contacts the app knows
    /// about. Hiding blocked from the list does not change it -- the
    /// onboarding empty state stays correct for users whose only contacts
    /// happen to all be blocked.
    func testContactCountIgnoresShowBlockedToggle() {
        let alice = Contact.mock(displayName: "Alice")
        let blockedBob = Contact.mock(displayName: "Bob", isBlocked: true)
        let repo = MockContactsRepository(contacts: [alice, blockedBob])

        let viewModel = ContactsViewModel(contactsRepository: repo)

        XCTAssertEqual(viewModel.contactCount, 2)
        viewModel.showBlocked = true
        XCTAssertEqual(viewModel.contactCount, 2)
    }

    /// Show-blocked composes with the audience filter: with both on,
    /// only blocked contacts in that audience appear.
    func testShowBlockedComposesWithAudienceFilter() {
        let alice = Contact.mock(displayName: "Alice")
        let blockedHuman = Contact.mock(displayName: "Bob", isBlocked: true)
        let blockedAgent = Contact.mock(
            displayName: "Coffee",
            isBlocked: true,
            agentVerification: .verified(.convos),
            agentTemplateId: "tmpl-coffee"
        )
        let repo = MockContactsRepository(contacts: [alice, blockedHuman, blockedAgent])

        let viewModel = ContactsViewModel(contactsRepository: repo)
        viewModel.showBlocked = true
        viewModel.filter = .agents

        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        // Show-blocked + agents-only -> only the blocked agent appears.
        XCTAssertEqual(allIds, [blockedAgent.inboxId])
    }

    /// `isFiltering` should fire on the show-blocked toggle alone, so the
    /// view can branch on "filtered empty state" rather than "no contacts
    /// onboarding state" when the toggle is the only narrowing predicate.
    func testIsFilteringTracksShowBlockedToggle() {
        let viewModel = ContactsViewModel(contactsRepository: MockContactsRepository())

        XCTAssertFalse(viewModel.isFiltering)
        viewModel.showBlocked = true
        XCTAssertTrue(viewModel.isFiltering)
        viewModel.showBlocked = false
        XCTAssertFalse(viewModel.isFiltering)
    }

    /// `clearFilters()` is invoked from the filtered-empty-state "Show all"
    /// button. It must reset the show-blocked toggle alongside the audience
    /// filter and search query so "Show all" matches the default load.
    func testClearFiltersResetsShowBlocked() {
        let viewModel = ContactsViewModel(contactsRepository: MockContactsRepository())

        viewModel.showBlocked = true
        viewModel.filter = .agents
        viewModel.searchQuery = "alice"

        viewModel.clearFilters()

        XCTAssertFalse(viewModel.showBlocked)
        XCTAssertEqual(viewModel.filter, .all)
        XCTAssertTrue(viewModel.searchQuery.isEmpty)
    }
}
