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

    /// The tab browses people. Every shape of agent - template-backed,
    /// legacy verified, unverified - stays in `DBContact` for chat-side
    /// resolution and for the contacts picker, but none of them appear here.
    func testSectionsShowPeopleOnly() async {
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

        let viewModel = await makeLoadedViewModel(
            contacts: [alice, coffeeAgent, legacyAssistant, unverifiedAgent]
        )

        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds, [alice.inboxId], "no agent of any shape is browsable here")
    }

    /// `contactCount` drives the empty-state vs list-state branch in the
    /// `ContactsView` body and the compose button's enabled flag. It counts
    /// only browsable rows, so agents do not inflate the total.
    func testContactCountCountsBrowsableRowsOnly() async {
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

        let viewModel = await makeLoadedViewModel(contacts: [alice, coffeeAgent, legacyAssistant])

        XCTAssertEqual(viewModel.contactCount, 1)
        XCTAssertEqual(viewModel.sections.flatMap { $0.rows }.count, 1)
    }

    // MARK: - Search

    func testSearchQueryFiltersResultsCaseInsensitively() async {
        let alice = Contact.mock(displayName: "Alice")
        let bob = Contact.mock(displayName: "Bob")
        let charlie = Contact.mock(displayName: "Charlie")

        let viewModel = await makeLoadedViewModel(contacts: [alice, bob, charlie])

        viewModel.searchQuery = "ALI"
        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds, [alice.inboxId])
    }

    func testSearchMatchesPeopleOnly() async {
        let alice = Contact.mock(displayName: "Alice")
        let aliceAssistant = Contact.mock(
            displayName: "Alice Assistant",
            agentVerification: .verified(.convos),
            agentTemplateId: "tmpl-alice"
        )
        let bob = Contact.mock(displayName: "Bob")

        let viewModel = await makeLoadedViewModel(contacts: [alice, aliceAssistant, bob])

        // The agent shares her name but is not browsable, so only Alice matches.
        viewModel.searchQuery = "alice"
        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds, [alice.inboxId])
    }

    // MARK: - Filtered empty state

    /// `isFiltering` distinguishes "nothing matched the search" from "no
    /// contacts at all", so the view keeps the search bar and shows the
    /// "Show all" empty state instead of the onboarding empty state.
    func testIsFilteringReflectsSearch() {
        let repo = MockContactsRepository(contacts: [.mock(displayName: "Alice")])
        let viewModel = ContactsViewModel(contactsRepository: repo)

        XCTAssertFalse(viewModel.isFiltering)

        viewModel.searchQuery = "  "
        XCTAssertFalse(viewModel.isFiltering, "whitespace-only query is not filtering")

        viewModel.searchQuery = "zzz"
        XCTAssertTrue(viewModel.isFiltering)

        viewModel.searchQuery = ""
        XCTAssertFalse(viewModel.isFiltering)
    }

    /// "Show all" clears the text search, so the full list comes back and
    /// `isFiltering` reads false again.
    func testClearFiltersRestoresFullList() async {
        let alice = Contact.mock(displayName: "Alice")
        let bob = Contact.mock(displayName: "Bob")

        let viewModel = await makeLoadedViewModel(contacts: [alice, bob])

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
    func testBlockedContactsHiddenByDefault() async {
        let alice = Contact.mock(displayName: "Alice")
        let blockedBob = Contact.mock(displayName: "Bob", isBlocked: true)

        let viewModel = await makeLoadedViewModel(contacts: [alice, blockedBob])

        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds, [alice.inboxId])
    }

    func testShowBlockedToggleRevealsBlockedRows() async {
        let alice = Contact.mock(displayName: "Alice")
        let blockedBob = Contact.mock(displayName: "Bob", isBlocked: true)

        let viewModel = await makeLoadedViewModel(contacts: [alice, blockedBob])
        viewModel.showBlocked = true

        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds.sorted(), [alice.inboxId, blockedBob.inboxId].sorted())
    }

    /// `contactCount` is the unfiltered count of contacts the app knows
    /// about. Hiding blocked from the list does not change it -- the
    /// onboarding empty state stays correct for users whose only contacts
    /// happen to all be blocked.
    func testContactCountIgnoresShowBlockedToggle() async {
        let alice = Contact.mock(displayName: "Alice")
        let blockedBob = Contact.mock(displayName: "Bob", isBlocked: true)

        let viewModel = await makeLoadedViewModel(contacts: [alice, blockedBob])

        XCTAssertEqual(viewModel.contactCount, 2)
        viewModel.showBlocked = true
        XCTAssertEqual(viewModel.contactCount, 2)
    }

    /// Show-blocked reveals blocked people and no one else: a blocked agent is
    /// still not browsable here.
    func testShowBlockedRevealsBlockedPeopleOnly() async {
        let alice = Contact.mock(displayName: "Alice")
        let blockedHuman = Contact.mock(displayName: "Bob", isBlocked: true)
        let blockedAgent = Contact.mock(
            displayName: "Coffee",
            isBlocked: true,
            agentVerification: .verified(.convos),
            agentTemplateId: "tmpl-coffee"
        )

        let viewModel = await makeLoadedViewModel(contacts: [alice, blockedHuman, blockedAgent])
        viewModel.showBlocked = true

        let allIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.contact.inboxId) }
        XCTAssertEqual(allIds.sorted(), [alice.inboxId, blockedHuman.inboxId].sorted())
        XCTAssertFalse(allIds.contains(blockedAgent.inboxId))
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
    /// button. It must reset the show-blocked toggle alongside the search
    /// query so "Show all" matches the default load.
    func testClearFiltersResetsShowBlocked() {
        let viewModel = ContactsViewModel(contactsRepository: MockContactsRepository())

        viewModel.showBlocked = true
        viewModel.searchQuery = "alice"

        viewModel.clearFilters()

        XCTAssertFalse(viewModel.showBlocked)
        XCTAssertTrue(viewModel.searchQuery.isEmpty)
    }

    // MARK: - Helpers

    /// The first contact load is asynchronous: the repository publisher
    /// delivers on the main queue and the first-paint fetch runs detached, so
    /// `sections` and `contactCount` are empty until one of them lands.
    /// Anything asserting on rows has to wait for that.
    private func makeLoadedViewModel(
        contacts: [Contact],
        timeout: TimeInterval = 2
    ) async -> ContactsViewModel {
        let viewModel = ContactsViewModel(
            contactsRepository: MockContactsRepository(contacts: contacts)
        )
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.isLoading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(viewModel.isLoading, "contacts never loaded")
        return viewModel
    }
}
