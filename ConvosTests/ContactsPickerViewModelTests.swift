import Combine
@testable import Convos
import ConvosCore
import XCTest

@MainActor
final class ContactsPickerViewModelTests: XCTestCase {
    // Test-only state, mutated only from main-thread test bodies and the
    // nonisolated XCTest tearDown; nonisolated(unsafe) lets both reach it
    // without an isolation hop.
    nonisolated(unsafe) private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Sectioning + sort

    func testAlphabeticalSectionsExcludeBlockedContactsByDefault() {
        let alice = Contact.mock(displayName: "Alice")
        let bob = Contact.mock(displayName: "Bob", isBlocked: true)
        let carl = Contact.mock(displayName: "Carl")
        let repo = MockContactsRepository(contacts: [alice, bob, carl])

        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: repo
        )

        let allRowIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(allRowIds.sorted(), [alice.inboxId, carl.inboxId].sorted())
    }

    /// New-conversation mode surfaces humans, template-backed agents, and
    /// verified template-less agents. Template-backed selections can spawn a
    /// fresh instance; template-less verified agents are added by inbox id.
    /// Unverified agents stay hidden.
    func testNewConversationShowsVerifiedAgentsIncludingTemplateLessAgents() {
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

        let viewModel = ContactsPickerViewModel(mode: .newConversation, contactsRepository: repo)

        let allRowIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(allRowIds.sorted(), [alice.inboxId, coffeeAgent.inboxId, legacyAssistant.inboxId].sorted())
    }

    /// Add-to-conversation mode surfaces humans and verified agents.
    func testAddToConversationShowsVerifiedAgents() {
        // Template-backed agents spawn a fresh instance into the existing
        // conversation; verified template-less agents are added by inbox id.
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

        let viewModel = ContactsPickerViewModel(
            mode: .addToConversation(conversationId: "convo-1", conversationTitle: nil),
            contactsRepository: repo
        )

        let allRowIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(allRowIds.sorted(), [alice.inboxId, coffeeAgent.inboxId, legacyAssistant.inboxId].sorted())
    }

    /// Multiple agents can be selected alongside humans; each selected
    /// agent contributes its template id to `selectedAgentTemplateIds`.
    func testMultipleAgentsCanBeSelected() {
        let alice = Contact.mock(displayName: "Alice")
        let coffee = Contact.mock(
            displayName: "Americano",
            agentVerification: .verified(.convos),
            agentTemplateId: "tmpl-coffee"
        )
        let tea = Contact.mock(
            displayName: "Earl Grey",
            agentVerification: .verified(.convos),
            agentTemplateId: "tmpl-tea"
        )
        let repo = MockContactsRepository(contacts: [alice, coffee, tea])
        let viewModel = ContactsPickerViewModel(mode: .newConversation, contactsRepository: repo)

        viewModel.toggleSelection(for: alice.inboxId)
        viewModel.toggleSelection(for: coffee.inboxId)
        XCTAssertEqual(viewModel.selectedAgentTemplateIds, ["tmpl-coffee"])

        // Selecting a second agent keeps both.
        viewModel.toggleSelection(for: tea.inboxId)
        XCTAssertTrue(viewModel.isSelected(inboxId: tea.inboxId))
        XCTAssertTrue(viewModel.isSelected(inboxId: coffee.inboxId))
        XCTAssertTrue(viewModel.isSelected(inboxId: alice.inboxId))
        XCTAssertEqual(viewModel.selectionCount, 3)
        XCTAssertEqual(Set(viewModel.selectedAgentTemplateIds), ["tmpl-coffee", "tmpl-tea"])
        XCTAssertEqual(viewModel.selectedAgentInboxIds, [coffee.inboxId, tea.inboxId])

        // Deselecting one agent leaves the other selected.
        viewModel.toggleSelection(for: coffee.inboxId)
        XCTAssertEqual(viewModel.selectedAgentTemplateIds, ["tmpl-tea"])
    }

    func testVerifiedTemplateLessAgentSelectionStaysInMemberInboxIds() {
        let assistant = Contact.mock(
            displayName: "Legacy Assistant",
            agentVerification: .verified(.convos)
        )
        let repo = MockContactsRepository(contacts: [assistant])
        let viewModel = ContactsPickerViewModel(mode: .newConversation, contactsRepository: repo)

        viewModel.toggleSelection(for: assistant.inboxId)

        XCTAssertEqual(viewModel.selectedInboxIds, [assistant.inboxId])
        XCTAssertTrue(viewModel.selectedAgentInboxIds.isEmpty)
        XCTAssertTrue(viewModel.selectedAgentTemplateIds.isEmpty)
    }

    func testHashBucketSortsLastForNonAlphaNames() {
        let alpha = Contact.mock(displayName: "Alpha")
        let pound = Contact.mock(displayName: "1Number")
        let zulu = Contact.mock(displayName: "Zulu")
        let repo = MockContactsRepository(contacts: [zulu, pound, alpha])

        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: repo
        )

        let titles: [String] = viewModel.sections.map(\.title)
        XCTAssertEqual(titles.last, "#")
        XCTAssertEqual(titles.first, "A")
    }

    // MARK: - Mode-driven copy

    func testHeaderTitleAndConfirmCopyForNewConversationMode() {
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository()
        )

        XCTAssertEqual(viewModel.headerTitle, "New conversation")

        let firstId = MockContactsRepository.defaultMockContacts[0].inboxId
        viewModel.toggleSelection(for: firstId)
        XCTAssertEqual(viewModel.confirmButtonTitle, "Continue")

        let secondId = MockContactsRepository.defaultMockContacts[1].inboxId
        viewModel.toggleSelection(for: secondId)
        XCTAssertEqual(viewModel.confirmButtonTitle, "Continue")
    }

    func testHeaderTitleAndConfirmCopyForAddToConversationMode() {
        let viewModel = ContactsPickerViewModel(
            mode: .addToConversation(conversationId: "convo-1", conversationTitle: "Dev Convosation"),
            contactsRepository: MockContactsRepository()
        )

        XCTAssertEqual(viewModel.headerTitle, "Add to Dev Convosation")

        let firstId = MockContactsRepository.defaultMockContacts[0].inboxId
        viewModel.toggleSelection(for: firstId)
        XCTAssertEqual(viewModel.confirmButtonTitle, "Continue")

        let secondId = MockContactsRepository.defaultMockContacts[1].inboxId
        viewModel.toggleSelection(for: secondId)
        XCTAssertEqual(viewModel.confirmButtonTitle, "Continue")
    }

    func testHeaderTitleFallsBackWhenConversationTitleMissing() {
        let viewModel = ContactsPickerViewModel(
            mode: .addToConversation(conversationId: "convo-1", conversationTitle: nil),
            contactsRepository: MockContactsRepository()
        )

        XCTAssertEqual(viewModel.headerTitle, "Add to convo")
    }

    // MARK: - Selection

    func testToggleSelectionTogglesAndCanConfirmReflectsCount() {
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository()
        )

        XCTAssertFalse(viewModel.canConfirm)

        let target = MockContactsRepository.defaultMockContacts[0].inboxId
        viewModel.toggleSelection(for: target)
        XCTAssertTrue(viewModel.canConfirm)
        XCTAssertEqual(viewModel.selectionCount, 1)
        XCTAssertTrue(viewModel.isSelected(inboxId: target))

        viewModel.toggleSelection(for: target)
        XCTAssertFalse(viewModel.canConfirm)
        XCTAssertFalse(viewModel.isSelected(inboxId: target))
    }

    func testToggleSelectionIgnoresAlreadyInChatContacts() {
        let alreadyIn = MockContactsRepository.defaultMockContacts[0].inboxId
        let viewModel = ContactsPickerViewModel(
            mode: .addToConversation(conversationId: "convo-1", conversationTitle: nil),
            contactsRepository: MockContactsRepository(),
            alreadyInChatInboxIds: [alreadyIn]
        )

        viewModel.toggleSelection(for: alreadyIn)
        XCTAssertFalse(viewModel.isSelected(inboxId: alreadyIn))
        XCTAssertEqual(viewModel.selectionCount, 0)
    }

    func testPreselectionIsSubtractedByAlreadyInChat() {
        let mocks = MockContactsRepository.defaultMockContacts
        let inChat = mocks[0].inboxId
        let preselected: Set<String> = [mocks[0].inboxId, mocks[1].inboxId]

        let viewModel = ContactsPickerViewModel(
            mode: .addToConversation(conversationId: "convo-1", conversationTitle: nil),
            contactsRepository: MockContactsRepository(),
            alreadyInChatInboxIds: [inChat],
            preselectedInboxIds: preselected
        )

        XCTAssertEqual(viewModel.selectionCount, 1)
        XCTAssertFalse(viewModel.isSelected(inboxId: inChat))
        XCTAssertTrue(viewModel.isSelected(inboxId: mocks[1].inboxId))
    }

    // MARK: - Search

    func testSearchQueryFiltersResultsCaseInsensitively() {
        let alice = Contact.mock(displayName: "Alice")
        let bob = Contact.mock(displayName: "Bob")
        let charlie = Contact.mock(displayName: "Charlie")
        let repo = MockContactsRepository(contacts: [alice, bob, charlie])

        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: repo
        )

        viewModel.searchQuery = "ALI"
        let allRowIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(allRowIds, [alice.inboxId])
    }

    func testEmptySearchQueryShowsEverything() {
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository()
        )
        viewModel.searchQuery = "z"
        viewModel.searchQuery = ""
        let count: Int = viewModel.sections.reduce(into: 0) { $0 += $1.rows.count }
        XCTAssertEqual(count, MockContactsRepository.defaultMockContacts.count)
    }

    // MARK: - In-chat row marking

    func testRowsCarryAlreadyInChatFlag() {
        let mocks = MockContactsRepository.defaultMockContacts
        let inChat = mocks[0].inboxId
        let viewModel = ContactsPickerViewModel(
            mode: .addToConversation(conversationId: "convo-1", conversationTitle: nil),
            contactsRepository: MockContactsRepository(),
            alreadyInChatInboxIds: [inChat]
        )

        let inChatRow = viewModel.sections.flatMap(\.rows).first { $0.id == inChat }
        XCTAssertEqual(inChatRow?.isAlreadyInChat, true)

        let otherRow = viewModel.sections.flatMap(\.rows).first { $0.id == mocks[1].inboxId }
        XCTAssertEqual(otherRow?.isAlreadyInChat, false)
    }

    // MARK: - Reactivity

    func testSelectionsArePrunedWhenContactsAreRemoved() async throws {
        let mocks = MockContactsRepository.defaultMockContacts
        let repo = MockContactsRepository(contacts: mocks)
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: repo
        )

        let removed = mocks[0].inboxId
        let kept = mocks[1].inboxId
        viewModel.toggleSelection(for: removed)
        viewModel.toggleSelection(for: kept)

        repo.setContacts(mocks.filter { $0.inboxId != removed })

        // Yield to the main queue so the .receive(on: DispatchQueue.main)
        // operator on the publisher subscription has a chance to deliver.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(viewModel.isSelected(inboxId: removed))
        XCTAssertTrue(viewModel.isSelected(inboxId: kept))
    }

    // MARK: - pickableContacts (Compose skip decision)

    /// `pickableContacts` is the shared filter the Compose flow uses to decide
    /// whether the picker is worth showing. It must agree with what the picker
    /// renders -- named humans and verified agents, not blocked or hidden rows.
    func testPickableContactsKeepsNamedHumans() {
        let alice = Contact.mock(displayName: "Alice")
        let bob = Contact.mock(displayName: "Bob")
        let result = ContactsPickerViewModel.pickableContacts([alice, bob])
        XCTAssertEqual(result.map(\.inboxId).sorted(), [alice.inboxId, bob.inboxId].sorted())
    }

    func testPickableContactsExcludesBlocked() {
        let alice = Contact.mock(displayName: "Alice")
        let blocked = Contact.mock(displayName: "Blocked", isBlocked: true)
        let result = ContactsPickerViewModel.pickableContacts([alice, blocked])
        XCTAssertEqual(result.map(\.inboxId), [alice.inboxId])
    }

    func testPickableContactsKeepsVerifiedAgents() {
        let alice = Contact.mock(displayName: "Alice")
        let convosAgent = Contact.mock(displayName: "Convos Assistant", agentVerification: .verified(.convos))
        let oauthAgent = Contact.mock(displayName: "OAuth Bot", agentVerification: .verified(.userOAuth))
        let result = ContactsPickerViewModel.pickableContacts([alice, convosAgent, oauthAgent])
        XCTAssertEqual(
            result.map(\.inboxId).sorted(),
            [alice.inboxId, convosAgent.inboxId, oauthAgent.inboxId].sorted()
        )
    }

    func testPickableContactsExcludesUnnamed() {
        let named = Contact.mock(displayName: "Named")
        let nilName = Contact.mock(displayName: nil)
        let emptyName = Contact.mock(displayName: "")
        let result = ContactsPickerViewModel.pickableContacts([named, nilName, emptyName])
        XCTAssertEqual(result.map(\.inboxId), [named.inboxId])
    }

    /// Hidden / blocked / unnamed contacts collapse to empty -- which is exactly
    /// what makes Compose skip the picker and open the new-conversation view
    /// directly (the bug behind the "13 contacts but empty picker" report).
    func testPickableContactsEmptyWhenNonePickable() {
        let unverifiedAgent = Contact.mock(displayName: "Agent", agentVerification: .unverified)
        let blocked = Contact.mock(displayName: "Blocked", isBlocked: true)
        let unnamed = Contact.mock(displayName: nil)
        XCTAssertTrue(ContactsPickerViewModel.pickableContacts([unverifiedAgent, blocked, unnamed]).isEmpty)
    }

    // MARK: - Suggested agents

    private func suggestedSection(_ viewModel: ContactsPickerViewModel) -> ContactsPickerViewModel.Section? {
        viewModel.sections.first { $0.id == SuggestedAgentsSection.id }
    }

    private func suggestedTemplateIds(_ viewModel: ContactsPickerViewModel) -> [String] {
        suggestedSection(viewModel)?.rows.compactMap { $0.contact.agentTemplateId } ?? []
    }

    /// With no service wired, the picker behaves exactly as before -- no
    /// suggested section and no extra rows.
    func testNoSuggestedSectionWithoutService() async {
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository()
        )
        await viewModel.loadSuggestedAgentsIfNeeded()
        XCTAssertNil(suggestedSection(viewModel))
    }

    /// The suggested section is appended after the alphabetical contact
    /// sections, with its sentinel id and "Suggested agents" title.
    func testSuggestedSectionAppearsAfterContacts() async {
        let service = MockSuggestedAgentsService(agents: [
            .mock(templateId: "trip", name: "Trip"),
            .mock(templateId: "chef", name: "Chef"),
        ])
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(),
            suggestedAgentsService: service
        )
        await viewModel.loadSuggestedAgentsIfNeeded()

        XCTAssertEqual(viewModel.sections.last?.id, SuggestedAgentsSection.id)
        XCTAssertEqual(viewModel.sections.last?.title, "Suggested agents")
        XCTAssertEqual(suggestedTemplateIds(viewModel), ["trip", "chef"])
        XCTAssertTrue(suggestedSection(viewModel)?.rows.allSatisfy(\.isSuggestedAgent) == true)
    }

    /// Always fetches a full page of 20 featured agents, whether or not the
    /// user already has contacts.
    func testInitialLimitIsTwentyWhenUserHasContacts() async {
        let service = MockSuggestedAgentsService(agents: [.mock(templateId: "a", name: "A")])
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(),
            suggestedAgentsService: service
        )
        await viewModel.loadSuggestedAgentsIfNeeded()
        XCTAssertEqual(service.requestedLimits.first, 20)
    }

    func testInitialLimitIsTwentyWhenUserHasNoContacts() async {
        let service = MockSuggestedAgentsService(agents: [.mock(templateId: "a", name: "A")])
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(contacts: []),
            suggestedAgentsService: service
        )
        await viewModel.loadSuggestedAgentsIfNeeded()
        XCTAssertEqual(service.requestedLimits.first, 20)
    }

    /// Scrolling to the bottom loads the next page (threading the cursor) and
    /// appends it, until the backend reports no more.
    func testPaginationAppendsNextPage() async {
        let service = MockSuggestedAgentsService(pages: [
            SuggestedAgentsPage(agents: [.mock(templateId: "a", name: "A"), .mock(templateId: "b", name: "B")], nextCursor: "cursor-1"),
            SuggestedAgentsPage(agents: [.mock(templateId: "c", name: "C")], nextCursor: nil),
        ])
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(contacts: []),
            suggestedAgentsService: service
        )

        await viewModel.loadSuggestedAgentsIfNeeded()
        XCTAssertEqual(suggestedTemplateIds(viewModel), ["a", "b"])

        await viewModel.loadMoreSuggestedAgents()
        XCTAssertEqual(suggestedTemplateIds(viewModel), ["a", "b", "c"])
        XCTAssertEqual(service.requestedCursors, [nil, "cursor-1"])

        // No further cursor -> a subsequent load-more is a no-op.
        await viewModel.loadMoreSuggestedAgents()
        XCTAssertEqual(service.requestedLimits.count, 2)
    }

    /// Selecting a suggested agent resolves it by template id through the
    /// synthetic contact backing its row.
    func testSelectingSuggestedAgentSetsTemplateId() async {
        let service = MockSuggestedAgentsService(agents: [.mock(templateId: "trip", name: "Trip")])
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(contacts: []),
            suggestedAgentsService: service
        )
        await viewModel.loadSuggestedAgentsIfNeeded()

        let row = try? XCTUnwrap(suggestedSection(viewModel)?.rows.first)
        let rowId = row?.id ?? ""
        viewModel.toggleSelection(for: rowId)

        XCTAssertTrue(viewModel.isSelected(inboxId: rowId))
        XCTAssertEqual(viewModel.selectedAgentTemplateIds, ["trip"])
        XCTAssertEqual(viewModel.selectedAgentInboxIds, [rowId])
        XCTAssertEqual(viewModel.selectedContacts.map(\.inboxId), [rowId])
    }

    /// A suggested agent the user already has as a (template-backed) contact is
    /// dropped from the suggested section so it never appears twice.
    func testSuggestedAgentsDedupedAgainstExistingContacts() async {
        let existing = Contact.mock(
            displayName: "Trip",
            agentVerification: .verified(.convos),
            agentTemplateId: "trip"
        )
        let service = MockSuggestedAgentsService(agents: [
            .mock(templateId: "trip", name: "Trip"),
            .mock(templateId: "chef", name: "Chef"),
        ])
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(contacts: [existing]),
            suggestedAgentsService: service
        )
        await viewModel.loadSuggestedAgentsIfNeeded()
        XCTAssertEqual(suggestedTemplateIds(viewModel), ["chef"])
    }

    /// The suggested section is a browse affordance: an active search hides it
    /// (the server-paged list can't be filtered against a partial set).
    func testSuggestedSectionHiddenWhileSearching() async {
        let service = MockSuggestedAgentsService(agents: [.mock(templateId: "trip", name: "Trip")])
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(),
            suggestedAgentsService: service
        )
        await viewModel.loadSuggestedAgentsIfNeeded()
        XCTAssertNotNil(suggestedSection(viewModel))

        viewModel.searchQuery = "zzz-no-match"
        XCTAssertNil(suggestedSection(viewModel))

        viewModel.searchQuery = ""
        XCTAssertNotNil(suggestedSection(viewModel))
    }

    // MARK: - Filtered empty state

    /// `isFiltering` lets the picker show the "Show all" empty state (rather
    /// than the generic "no contacts" one) when a search or audience filter
    /// matches nothing.
    func testIsFilteringReflectsSearchAndAudienceFilter() {
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(contacts: [.mock(displayName: "Alice")])
        )

        XCTAssertFalse(viewModel.isFiltering)

        viewModel.searchQuery = "zzz"
        XCTAssertTrue(viewModel.isFiltering)

        viewModel.searchQuery = ""
        XCTAssertFalse(viewModel.isFiltering)

        viewModel.filter = .agents
        XCTAssertTrue(viewModel.isFiltering)
    }

    /// "Show all" clears the search and audience filter, restoring the full
    /// pickable list.
    func testClearFiltersRestoresFullList() {
        let alice = Contact.mock(displayName: "Alice")
        let bob = Contact.mock(displayName: "Bob")
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(contacts: [alice, bob])
        )

        viewModel.searchQuery = "zzz"
        XCTAssertTrue(viewModel.sections.isEmpty)
        XCTAssertTrue(viewModel.isFiltering)

        viewModel.clearFilters()

        XCTAssertFalse(viewModel.isFiltering)
        let allRowIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(allRowIds.sorted(), [alice.inboxId, bob.inboxId].sorted())
    }
}
