import Combine
@testable import Convos
import ConvosCore
import XCTest

@MainActor
final class DocAgentMessageAggregatorTests: XCTestCase {
    func testStateFromNonObservedAgentConversationReachesParserAndRenders() async {
        let defaults = makeDefaults()
        let agent = agentMember()
        let observed = conversation(id: "observed-dm", agent: agent)
        let alternate = conversation(id: "agent-tab-lane", agent: agent)
        let repositories = [
            observed.id: TestDocMessagesRepository(conversationId: observed.id),
            alternate.id: TestDocMessagesRepository(
                conversationId: alternate.id,
                messages: [stateMessage(id: "state-alternate", name: "Alternate Lane", date: 200, sender: agent)]
            ),
        ]
        let conversations = CurrentValueSubject<[Conversation], Never>([observed, alternate])
        let viewModel = DocExperienceViewModel(
            session: MockInboxesService(),
            coreActions: NoOpCoreActions(),
            defaults: defaults
        )
        let aggregator = makeAggregator(conversations: conversations, repositories: repositories)
        let stateArrived = expectation(description: "alternate lane state arrived")
        var didFulfill = false

        aggregator.start(agentInboxId: agent.profile.inboxId) { messages in
            viewModel.ingestAggregatedMessages(messages, agentInboxId: agent.profile.inboxId)
            guard !didFulfill else { return }
            didFulfill = true
            stateArrived.fulfill()
        }

        await fulfillment(of: [stateArrived], timeout: 1)
        XCTAssertEqual(viewModel.docs.map(\.name), ["Alternate Lane"])
    }

    func testNewestStateWinsAcrossAgentConversationLanes() async {
        let defaults = makeDefaults()
        let agent = agentMember()
        let observed = conversation(id: "observed-dm", agent: agent)
        let alternate = conversation(id: "primary-lane", agent: agent)
        let repositories = [
            observed.id: TestDocMessagesRepository(
                conversationId: observed.id,
                messages: [stateMessage(id: "state-old", name: "Old State", date: 100, sender: agent)]
            ),
            alternate.id: TestDocMessagesRepository(
                conversationId: alternate.id,
                messages: [stateMessage(id: "state-new", name: "Newest State", date: 200, sender: agent)]
            ),
        ]
        let conversations = CurrentValueSubject<[Conversation], Never>([alternate, observed])
        let viewModel = DocExperienceViewModel(
            session: MockInboxesService(),
            coreActions: NoOpCoreActions(),
            defaults: defaults
        )
        let aggregator = makeAggregator(conversations: conversations, repositories: repositories)
        let statesArrived = expectation(description: "all lane states arrived")
        var didFulfill = false

        aggregator.start(agentInboxId: agent.profile.inboxId) { messages in
            viewModel.ingestAggregatedMessages(messages, agentInboxId: agent.profile.inboxId)
            guard !didFulfill else { return }
            didFulfill = true
            statesArrived.fulfill()
        }

        await fulfillment(of: [statesArrived], timeout: 1)
        XCTAssertEqual(viewModel.docs.map(\.name), ["Newest State"])
    }

    func testHistoricalStateBackfillsOnColdStartWithoutLiveEvents() async {
        let defaults = makeDefaults()
        let agent = agentMember()
        let historicalState = stateMessage(
            id: "historical-state",
            name: "Cold Start Card",
            date: 100,
            sender: agent
        )
        let lane = conversation(id: "historical-lane", agent: agent)
        let repository = TestDocMessagesRepository(
            conversationId: lane.id,
            historicalMessages: [historicalState],
            publishesMessages: false
        )
        let conversations = CurrentValueSubject<[Conversation], Never>([lane])
        let viewModel = DocExperienceViewModel(
            session: MockInboxesService(),
            coreActions: NoOpCoreActions(),
            defaults: defaults
        )
        let aggregator = makeAggregator(
            conversations: conversations,
            repositories: [lane.id: repository]
        )
        let stateArrived = expectation(description: "historical state backfilled")

        aggregator.start(agentInboxId: agent.profile.inboxId) { messages in
            viewModel.ingestAggregatedMessages(messages, agentInboxId: agent.profile.inboxId)
            if viewModel.docs.map(\.name) == ["Cold Start Card"] {
                stateArrived.fulfill()
            }
        }

        await fulfillment(of: [stateArrived], timeout: 1)
        XCTAssertEqual(viewModel.docs.map(\.name), ["Cold Start Card"])
    }

    private func makeAggregator(
        conversations: CurrentValueSubject<[Conversation], Never>,
        repositories: [String: TestDocMessagesRepository]
    ) -> DocAgentMessageAggregator {
        DocAgentMessageAggregator(
            conversationsPublisher: conversations.eraseToAnyPublisher(),
            repositoryProvider: { conversationId -> any MessagesRepositoryProtocol in
                if let repository = repositories[conversationId] {
                    return repository
                }
                return MockMessagesRepository(conversationId: conversationId)
            }
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "DocAgentMessageAggregatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func agentMember() -> ConversationMember {
        ConversationMember(
            profile: .mock(inboxId: "doc-agent", name: "Doc"),
            role: .member,
            isCurrentUser: false,
            isAgent: true
        )
    }

    private func conversation(id: String, agent: ConversationMember) -> Conversation {
        .mock(
            id: id,
            members: [
                .mock(isCurrentUser: true),
                agent,
            ]
        )
    }

    private func stateMessage(
        id: String,
        name: String,
        date: TimeInterval,
        sender: ConversationMember
    ) -> AnyMessage {
        let text = #"⟦doc⟧{"v":1,"t":"state","docs":[{"id":"trip","name":"\#(name)","url":"https://docs.google.com/document/d/1","updatedAt":\#(Int(date)),"lastChange":{"who":"Sara","what":"updated the plan","at":\#(Int(date))},"binding":{"state":"live","number":"+16285550123","group":"Trip"}}]}"#
        return .message(
            Message(
                id: id,
                sender: sender,
                source: .incoming,
                status: .published,
                content: .text(text),
                date: Date(timeIntervalSince1970: date),
                reactions: []
            ),
            .existing
        )
    }
}

private final class TestDocMessagesRepository: MessagesRepositoryProtocol, @unchecked Sendable {
    private let subject: CurrentValueSubject<[AnyMessage], Never>
    private let conversationId: String
    private let historicalMessages: [AnyMessage]
    private let publishesMessages: Bool

    init(
        conversationId: String,
        messages: [AnyMessage] = [],
        historicalMessages: [AnyMessage]? = nil,
        publishesMessages: Bool = true
    ) {
        self.conversationId = conversationId
        self.subject = CurrentValueSubject(messages)
        self.historicalMessages = historicalMessages ?? messages
        self.publishesMessages = publishesMessages
    }

    var messagesPublisher: AnyPublisher<[AnyMessage], Never> {
        guard publishesMessages else {
            return Empty(completeImmediately: false).eraseToAnyPublisher()
        }
        return subject.eraseToAnyPublisher()
    }

    var conversationMessagesResultPublisher: AnyPublisher<ConversationMessagesResult, Never> {
        Empty().eraseToAnyPublisher()
    }

    var hasMoreMessages: Bool { false }

    func fetchInitial() throws -> [AnyMessage] {
        subject.value
    }

    func fetchInitialResult() throws -> ConversationMessagesResult {
        fatalError("Unused by DocAgentMessageAggregatorTests")
    }

    func fetchRecent(limit: Int) throws -> [AnyMessage] {
        Array(historicalMessages.prefix(limit))
    }

    func fetchPrevious() throws {}
}
