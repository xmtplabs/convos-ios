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

    // MARK: - Helpers

    private func humanRowIds(_ viewModel: ContactsPickerViewModel) -> [String] {
        viewModel.sections.flatMap { $0.rows }.compactMap { row in
            if case .human(let contact) = row.kind { return contact.inboxId }
            return nil
        }
    }

    private func agentRowIds(_ viewModel: ContactsPickerViewModel) -> [String] {
        viewModel.sections.flatMap { $0.rows }.compactMap { row in
            if case .agentTemplate(let agent) = row.kind { return agent.templateId }
            return nil
        }
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

        XCTAssertEqual(humanRowIds(viewModel).sorted(), [alice.inboxId, carl.inboxId].sorted())
    }

    /// Verified-agent contacts (Convos / OAuth-attested assistants) live in
    /// `DBContact` so chat-side surfaces can resolve them, but the picker
    /// browses humans only. Regression guard: if the predicate ever stops
    /// filtering them, agents would surface in every "Start a convo" /
    /// "Add to convo" flow.
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

        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: repo
        )

        // Alice and the unverified agent pass through; both verified agents
        // are filtered out. Unverified agents intentionally remain visible
        // because they're not yet attested.
        XCTAssertEqual(humanRowIds(viewModel).sorted(), [alice.inboxId, unverifiedAgent.inboxId].sorted())
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
        viewModel.toggleSelection(.human(inboxId: firstId))
        XCTAssertEqual(viewModel.confirmButtonTitle, "Continue")

        let secondId = MockContactsRepository.defaultMockContacts[1].inboxId
        viewModel.toggleSelection(.human(inboxId: secondId))
        XCTAssertEqual(viewModel.confirmButtonTitle, "Continue")
    }

    func testHeaderTitleAndConfirmCopyForAddToConversationMode() {
        let viewModel = ContactsPickerViewModel(
            mode: .addToConversation(conversationId: "convo-1", conversationTitle: "Dev Convosation"),
            contactsRepository: MockContactsRepository()
        )

        XCTAssertEqual(viewModel.headerTitle, "Add to Dev Convosation")

        let firstId = MockContactsRepository.defaultMockContacts[0].inboxId
        viewModel.toggleSelection(.human(inboxId: firstId))
        XCTAssertEqual(viewModel.confirmButtonTitle, "Continue")

        let secondId = MockContactsRepository.defaultMockContacts[1].inboxId
        viewModel.toggleSelection(.human(inboxId: secondId))
        XCTAssertEqual(viewModel.confirmButtonTitle, "Continue")
    }

    func testHeaderTitleFallsBackWhenConversationTitleMissing() {
        let viewModel = ContactsPickerViewModel(
            mode: .addToConversation(conversationId: "convo-1", conversationTitle: nil),
            contactsRepository: MockContactsRepository()
        )

        XCTAssertEqual(viewModel.headerTitle, "Add to convo")
    }

    // MARK: - Selection (humans)

    func testToggleSelectionTogglesAndCanConfirmReflectsCount() {
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository()
        )

        XCTAssertFalse(viewModel.canConfirm)

        let target = MockContactsRepository.defaultMockContacts[0].inboxId
        let selection: ContactsPickerViewModel.Selection = .human(inboxId: target)
        viewModel.toggleSelection(selection)
        XCTAssertTrue(viewModel.canConfirm)
        XCTAssertEqual(viewModel.selectionCount, 1)
        XCTAssertTrue(viewModel.isSelected(selection))

        viewModel.toggleSelection(selection)
        XCTAssertFalse(viewModel.canConfirm)
        XCTAssertFalse(viewModel.isSelected(selection))
    }

    func testToggleSelectionIgnoresAlreadyInChatContacts() {
        let alreadyIn = MockContactsRepository.defaultMockContacts[0].inboxId
        let viewModel = ContactsPickerViewModel(
            mode: .addToConversation(conversationId: "convo-1", conversationTitle: nil),
            contactsRepository: MockContactsRepository(),
            alreadyInChatInboxIds: [alreadyIn]
        )

        viewModel.toggleSelection(.human(inboxId: alreadyIn))
        XCTAssertFalse(viewModel.isSelected(.human(inboxId: alreadyIn)))
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
        XCTAssertFalse(viewModel.isSelected(.human(inboxId: inChat)))
        XCTAssertTrue(viewModel.isSelected(.human(inboxId: mocks[1].inboxId)))
    }

    // MARK: - Selection (agent templates)

    func testAgentTemplatesAreSelectableAndMixWithHumans() {
        let alice = Contact.mock(displayName: "Alice")
        let bob = Contact.mock(displayName: "Bob")
        let tifoso = AgentTemplateContact.mock(displayName: "Tifoso", emoji: "🚴")
        let tripPlanner = AgentTemplateContact.mock(displayName: "Trip Planner", emoji: "🗺️")
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(contacts: [alice, bob]),
            agentTemplateContactsRepository: MockAgentTemplateContactsRepository(contacts: [tifoso, tripPlanner])
        )

        viewModel.toggleSelection(.human(inboxId: alice.inboxId))
        viewModel.toggleSelection(.agentTemplate(templateId: tifoso.templateId))
        viewModel.toggleSelection(.agentTemplate(templateId: tripPlanner.templateId))

        XCTAssertEqual(viewModel.selectionCount, 3)
        XCTAssertEqual(Set(viewModel.selectedContacts.map(\.inboxId)), [alice.inboxId])
        XCTAssertEqual(
            Set(viewModel.selectedAgentContacts.map(\.templateId)),
            [tifoso.templateId, tripPlanner.templateId]
        )
    }

    /// Agent-template rows are surfaced in the picker sections (unlike
    /// verified humans, which are filtered out). Regression guard for the
    /// 2.4 picker integration.
    func testAgentTemplateRowsAppearInSections() {
        let tifoso = AgentTemplateContact.mock(displayName: "Tifoso", emoji: "🚴")
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(contacts: []),
            agentTemplateContactsRepository: MockAgentTemplateContactsRepository(contacts: [tifoso])
        )

        XCTAssertEqual(agentRowIds(viewModel), [tifoso.templateId])
    }

    /// Selecting / deselecting an agent template via the explicit `Selection`
    /// API round-trips cleanly. The `templateId` accessor exposes the same
    /// id through both directions.
    func testAgentTemplateSelectionRoundTrips() {
        let tifoso = AgentTemplateContact.mock(displayName: "Tifoso", emoji: "🚴")
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(contacts: []),
            agentTemplateContactsRepository: MockAgentTemplateContactsRepository(contacts: [tifoso])
        )
        let selection: ContactsPickerViewModel.Selection = .agentTemplate(templateId: tifoso.templateId)

        XCTAssertFalse(viewModel.isSelected(selection))
        viewModel.toggleSelection(selection)
        XCTAssertTrue(viewModel.isSelected(selection))
        viewModel.deselect(selection)
        XCTAssertFalse(viewModel.isSelected(selection))
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
        XCTAssertEqual(humanRowIds(viewModel), [alice.inboxId])
    }

    func testSearchMatchesAgentTemplateNames() {
        let alice = Contact.mock(displayName: "Alice")
        let tifoso = AgentTemplateContact.mock(displayName: "Tifoso", emoji: "🚴")
        let tripPlanner = AgentTemplateContact.mock(displayName: "Trip Planner", emoji: "🗺️")
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(contacts: [alice]),
            agentTemplateContactsRepository: MockAgentTemplateContactsRepository(contacts: [tifoso, tripPlanner])
        )

        viewModel.searchQuery = "trip"
        XCTAssertEqual(humanRowIds(viewModel), [])
        XCTAssertEqual(agentRowIds(viewModel), [tripPlanner.templateId])
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

        let inChatRow = viewModel.sections.flatMap(\.rows).first { row in
            if case .human(let contact) = row.kind { return contact.inboxId == inChat }
            return false
        }
        XCTAssertEqual(inChatRow?.isAlreadyInChat, true)

        let otherRow = viewModel.sections.flatMap(\.rows).first { row in
            if case .human(let contact) = row.kind { return contact.inboxId == mocks[1].inboxId }
            return false
        }
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
        viewModel.toggleSelection(.human(inboxId: removed))
        viewModel.toggleSelection(.human(inboxId: kept))

        repo.setContacts(mocks.filter { $0.inboxId != removed })

        // Yield to the main queue so the .receive(on: DispatchQueue.main)
        // operator on the publisher subscription has a chance to deliver.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(viewModel.isSelected(.human(inboxId: removed)))
        XCTAssertTrue(viewModel.isSelected(.human(inboxId: kept)))
    }

    /// Agent-template pruning mirrors the human path: if the agent-template
    /// repo drops a row from underneath us (e.g. user removed the contact
    /// from another surface mid-picker), the selection drops too.
    func testAgentTemplateSelectionPrunedWhenContactRemoved() async throws {
        let tifoso = AgentTemplateContact.mock(displayName: "Tifoso", emoji: "🚴")
        let tripPlanner = AgentTemplateContact.mock(displayName: "Trip Planner", emoji: "🗺️")
        let repo = MockAgentTemplateContactsRepository(contacts: [tifoso, tripPlanner])
        let viewModel = ContactsPickerViewModel(
            mode: .newConversation,
            contactsRepository: MockContactsRepository(contacts: []),
            agentTemplateContactsRepository: repo
        )

        viewModel.toggleSelection(.agentTemplate(templateId: tifoso.templateId))
        viewModel.toggleSelection(.agentTemplate(templateId: tripPlanner.templateId))

        repo.setContacts([tripPlanner])

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(viewModel.isSelected(.agentTemplate(templateId: tifoso.templateId)))
        XCTAssertTrue(viewModel.isSelected(.agentTemplate(templateId: tripPlanner.templateId)))
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
}
