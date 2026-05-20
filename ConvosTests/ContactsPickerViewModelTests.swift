import Combine
@testable import Convos
import ConvosCore
import XCTest

@MainActor
final class ContactsPickerViewModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

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

        let allRowIds: [String] = viewModel.sections.flatMap { $0.rows.map(\.id) }
        // Alice and the unverified agent pass through; both verified agents
        // are filtered out. Unverified agents intentionally remain visible
        // because they're not yet attested - the user may still want to act
        // on them like any unknown contact.
        XCTAssertEqual(allRowIds.sorted(), [alice.inboxId, unverifiedAgent.inboxId].sorted())
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
