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

    /// New-conversation mode surfaces humans and template-backed agents
    /// (you can spawn a fresh instance into the new convo). Template-less
    /// agents - legacy verified assistants and unverified agents - stay
    /// hidden.
    func testNewConversationShowsTemplateBackedAgentsOnly() {
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
        XCTAssertEqual(allRowIds.sorted(), [alice.inboxId, coffeeAgent.inboxId].sorted())
    }

    /// Add-to-conversation mode is human-only - agents aren't spawned into
    /// an existing conversation from the picker.
    func testAddToConversationShowsAgents() {
        // Template-backed agents are selectable in add-to-conversation mode
        // too: confirming spawns a fresh instance of the template into the
        // existing conversation.
        let alice = Contact.mock(displayName: "Alice")
        let coffeeAgent = Contact.mock(
            displayName: "Americano",
            agentVerification: .verified(.convos),
            agentTemplateId: "tmpl-coffee"
        )
        let repo = MockContactsRepository(contacts: [alice, coffeeAgent])

        let viewModel = ContactsPickerViewModel(
            mode: .addToConversation(conversationId: "convo-1", conversationTitle: nil),
            contactsRepository: repo
        )

        let allRowIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(allRowIds, [alice.inboxId, coffeeAgent.inboxId])
    }

    /// At most one agent may be selected. Once an agent is selected, other
    /// agents are blocked (selecting a second is a no-op and their rows are
    /// disabled); the user must deselect the first to pick another. Humans
    /// are unrestricted.
    func testSecondAgentSelectionIsBlocked() {
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
        XCTAssertEqual(viewModel.selectedAgentTemplateId, "tmpl-coffee")
        XCTAssertFalse(viewModel.isAgentSelectionBlocked(for: coffee.inboxId), "the selected agent itself isn't blocked")
        XCTAssertTrue(viewModel.isAgentSelectionBlocked(for: tea.inboxId), "other agents are blocked once one is selected")

        // Tapping a second agent is a no-op: the first stays, the second is not added.
        viewModel.toggleSelection(for: tea.inboxId)
        XCTAssertEqual(viewModel.selectedAgentTemplateId, "tmpl-coffee")
        XCTAssertFalse(viewModel.isSelected(inboxId: tea.inboxId))
        XCTAssertTrue(viewModel.isSelected(inboxId: coffee.inboxId))
        XCTAssertTrue(viewModel.isSelected(inboxId: alice.inboxId))
        XCTAssertEqual(viewModel.selectionCount, 2)

        // Deselecting the agent unblocks the others.
        viewModel.toggleSelection(for: coffee.inboxId)
        XCTAssertNil(viewModel.selectedAgentTemplateId)
        XCTAssertFalse(viewModel.isAgentSelectionBlocked(for: tea.inboxId))
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
    /// renders -- named humans only, not blocked, not verified agents.
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

    func testPickableContactsExcludesVerifiedAgents() {
        let alice = Contact.mock(displayName: "Alice")
        let convosAgent = Contact.mock(displayName: "Convos Assistant", agentVerification: .verified(.convos))
        let oauthAgent = Contact.mock(displayName: "OAuth Bot", agentVerification: .verified(.userOAuth))
        let result = ContactsPickerViewModel.pickableContacts([alice, convosAgent, oauthAgent])
        XCTAssertEqual(result.map(\.inboxId), [alice.inboxId])
    }

    func testPickableContactsExcludesUnnamed() {
        let named = Contact.mock(displayName: "Named")
        let nilName = Contact.mock(displayName: nil)
        let emptyName = Contact.mock(displayName: "")
        let result = ContactsPickerViewModel.pickableContacts([named, nilName, emptyName])
        XCTAssertEqual(result.map(\.inboxId), [named.inboxId])
    }

    /// All agents / blocked / unnamed collapses to empty -- which is exactly
    /// what makes Compose skip the picker and open the new-conversation view
    /// directly (the bug behind the "13 contacts but empty picker" report).
    func testPickableContactsEmptyWhenNonePickable() {
        let agent = Contact.mock(displayName: "Agent", agentVerification: .verified(.convos))
        let blocked = Contact.mock(displayName: "Blocked", isBlocked: true)
        let unnamed = Contact.mock(displayName: nil)
        XCTAssertTrue(ContactsPickerViewModel.pickableContacts([agent, blocked, unnamed]).isEmpty)
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

    /// Selecting a suggested agent makes it the conversation's single agent
    /// (resolved by template id) and follows the one-agent rule.
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
        XCTAssertEqual(viewModel.selectedAgentTemplateId, "trip")
        XCTAssertEqual(viewModel.selectedAgentInboxId, rowId)
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
}
