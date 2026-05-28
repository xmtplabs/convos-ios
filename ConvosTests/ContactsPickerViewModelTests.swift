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
    func testAddToConversationHidesAgents() {
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
        XCTAssertEqual(allRowIds, [alice.inboxId])
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
}
