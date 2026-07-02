import Combine
@testable import Convos
import ConvosCore
import XCTest

/// Regression coverage for the member-engagement latch
/// (`ConversationViewModel.everHadOtherMembers`). The initial assignment
/// of `conversation` in init does not run its `didSet`, so a view model
/// created for a conversation that already has other members must latch
/// from the initial member list -- otherwise those members leaving would
/// make dismiss-cleanup read the conversation as never-engaged and
/// discard it.
@MainActor
final class ConversationViewModelEngagementLatchTests: XCTestCase {
    func testInitialMemberListLatchesEngagement() {
        let fixtures = makeFixtures(withOtherMember: true)

        XCTAssertTrue(fixtures.viewModel.everHadOtherMembers,
                      "A VM created for a conversation that already has other members must latch immediately")
    }

    func testInitialSoloMemberListDoesNotLatch() {
        let fixtures = makeFixtures(withOtherMember: false)

        XCTAssertFalse(fixtures.viewModel.everHadOtherMembers,
                       "A solo conversation must not read as member-engaged")
    }

    func testCallbackWiredAfterInitIsReplayed() {
        let fixtures = makeFixtures(withOtherMember: true)
        var memberJoinedFired = false

        // NewConversationViewModel wires this callback after init; the
        // init-time latch must replay into it so the wrapper's
        // `EngagementLatches` still record `.memberJoined`.
        fixtures.viewModel.onMemberJoined = { memberJoinedFired = true }

        XCTAssertTrue(memberJoinedFired,
                      "Wiring onMemberJoined after the latch fired must replay the signal")
    }

    func testLatchSurvivesMembersLeaving() {
        let fixtures = makeFixtures(withOtherMember: true)
        XCTAssertTrue(fixtures.viewModel.everHadOtherMembers)

        let soloConversation = Conversation.mock(
            id: Constant.conversationId,
            members: [.mock(isCurrentUser: true)]
        )
        fixtures.repository.subject.send(soloConversation)
        flushMainQueue()

        XCTAssertTrue(fixtures.viewModel.conversation.membersWithoutCurrent.isEmpty,
                      "The departure update should have landed on the view model")
        XCTAssertTrue(fixtures.viewModel.everHadOtherMembers,
                      "The latch must survive every member leaving")
    }

    // MARK: - Helpers

    private struct Fixtures {
        let viewModel: ConversationViewModel
        let repository: SubjectDraftConversationRepository
    }

    private func makeFixtures(withOtherMember: Bool) -> Fixtures {
        var members: [ConversationMember] = [.mock(isCurrentUser: true)]
        if withOtherMember {
            members.append(.mock(isCurrentUser: false, name: "Alice"))
        }
        let conversation = Conversation.mock(id: Constant.conversationId, members: members)
        let repository = SubjectDraftConversationRepository(conversation: conversation)
        let stateManager = MockConversationStateManager(
            conversationId: conversation.id,
            draftConversationRepository: repository
        )
        let viewModel = ConversationViewModel(
            conversation: conversation,
            session: MockInboxesService(),
            messagingService: MockMessagingService(conversationStateManager: stateManager),
            conversationStateManager: stateManager
        )
        return Fixtures(viewModel: viewModel, repository: repository)
    }

    /// The conversation publisher delivers on the main queue; one async
    /// hop drains everything scheduled before it.
    private func flushMainQueue() {
        let flushed = expectation(description: "main queue flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 2.0)
    }

    private enum Constant {
        static let conversationId: String = "engagement-latch-convo"
    }
}

/// Draft-conversation repository backed by a subject so tests can push
/// follow-up conversation updates (e.g. a member leaving) through the same
/// publisher the production repositories use.
private final class SubjectDraftConversationRepository: DraftConversationRepositoryProtocol, @unchecked Sendable {
    let subject: CurrentValueSubject<Conversation?, Never>

    init(conversation: Conversation) {
        self.subject = .init(conversation)
    }

    var conversationId: String {
        subject.value?.id ?? ""
    }

    var messagesRepository: any MessagesRepositoryProtocol {
        MockMessagesRepository(conversationId: conversationId)
    }

    var myProfileRepository: any MyProfileRepositoryProtocol {
        MockMyProfileRepository()
    }

    var conversationPublisher: AnyPublisher<Conversation?, Never> {
        subject.eraseToAnyPublisher()
    }

    func fetchConversation() throws -> Conversation? {
        subject.value
    }
}
