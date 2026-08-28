import Combine
@testable import Convos
import ConvosCore
import XCTest

@MainActor
final class DocAgentMessageAggregatorTests: XCTestCase {
    func testLiveHiddenLaneAppliesStateItemMintAndItemResolution() async {
        let defaults = makeDefaults()
        let agent = agentMember()
        let hiddenPrimary = conversation(id: "hidden-primary", agent: agent)
        let repository = TestDocMessagesRepository(conversationId: hiddenPrimary.id)
        let conversations = CurrentValueSubject<[Conversation], Never>([hiddenPrimary])
        let viewModel = DocExperienceViewModel(
            session: MockInboxesService(),
            coreActions: NoOpCoreActions(),
            defaults: defaults
        )
        let aggregator = makeAggregator(
            conversations: conversations,
            repositories: [hiddenPrimary.id: repository]
        )
        let state = stateMessage(id: "state-live", name: "Live State", date: 100, sender: agent)
        let item = wireMessage(
            id: "z-item-live",
            text: #"⟦doc⟧{"v":1,"t":"item","item":{"id":"question-live","register":"waiting","kind":"question","headline":"Which date works?","context":"The trip needs a date.","chips":["Friday"],"docId":null,"createdAt":101}}"#,
            date: 101,
            sender: agent
        )
        let resolved = wireMessage(
            id: "a-resolved-live",
            text: #"⟦doc⟧{"v":1,"t":"item-resolved","id":"question-live"}"#,
            date: 101,
            sender: agent
        )
        let stateArrived = expectation(description: "live state applied")
        let itemArrived = expectation(description: "live item mint applied")
        let resolutionArrived = expectation(description: "live item resolution applied")
        var sawState = false
        var sawItem = false
        var sawResolution = false

        aggregator.start(agentInboxId: agent.profile.inboxId) { messages in
            viewModel.ingestAggregatedMessages(messages, agentInboxId: agent.profile.inboxId)
            if !sawState, viewModel.docs.map(\.name) == ["Live State"] {
                sawState = true
                stateArrived.fulfill()
            }
            if !sawItem, viewModel.pendingItems.map(\.id) == ["question-live"] {
                sawItem = true
                itemArrived.fulfill()
            }
            if sawItem, !sawResolution, viewModel.pendingItems.isEmpty {
                sawResolution = true
                resolutionArrived.fulfill()
            }
        }

        repository.publish([state])
        await fulfillment(of: [stateArrived], timeout: 1)
        repository.publish([state, item])
        await fulfillment(of: [itemArrived], timeout: 1)
        repository.publish([state, item, resolved])
        await fulfillment(of: [resolutionArrived], timeout: 1)
        XCTAssertTrue(viewModel.pendingItems.isEmpty)
    }

    func testCurrentPublisherStateAndControlVerificationReachHomeSnapshot() async {
        let defaults = makeDefaults()
        let agent = agentMember()
        let lane = conversation(id: "primary-lane", agent: agent)
        let stateText = #"⟦doc⟧{"v":1,"t":"state","line":"+16283095734","docs":[{"id":"tahoe-trip","name":"Tahoe Trip","url":"https://docs.google.com/document/d/doc-123/edit","updatedAt":1787720400,"lastChange":{"who":"Sara","what":"created the doc","at":1787720340},"binding":{"state":"pending","number":"+16283095734","group":null},"shared":false,"dates":"Dec 12–15","people":4}]}"#
        let lineText = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":2,"at":1787720399,"key":"line","kind":"line","line":{"status":"available","lineNumber":"+16283095734"}}"#
        let verificationText = #"⟦doc⟧{"v":1,"t":"control","instanceId":"F47AC10B-58CC-4372-A567-0E02B2C3D479","epoch":"7D9E6679-7425-40DE-944B-E07FC1F90AE7","seq":3,"at":1787720400,"key":"verification:challenge","kind":"verification","verification":{"status":"pending","challengeId":"A8098C1A-F86E-11DA-BD1A-00112444BE1E","lineNumber":"+16283095734","ownerNumber":null,"code":"ABCD-EFGH-2345","smsBody":"VERIFY ABCD-EFGH-2345","expiresAt":1787724000,"verifiedAt":null,"releasedAt":null,"clearsKey":null}}"#
        let repository = TestDocMessagesRepository(
            conversationId: lane.id,
            messages: [
                wireMessage(id: "publisher-state", text: stateText, date: 200, sender: agent),
                wireMessage(id: "publisher-line", text: lineText, date: 199, sender: agent),
                wireMessage(id: "publisher-verification", text: verificationText, date: 201, sender: agent),
            ]
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
        let snapshotArrived = expectation(description: "publisher snapshot reached home")
        var didFulfill = false

        aggregator.start(agentInboxId: agent.profile.inboxId) { messages in
            viewModel.ingestAggregatedMessages(messages, agentInboxId: agent.profile.inboxId)
            guard !didFulfill,
                  viewModel.docs.map(\.id) == ["tahoe-trip"],
                  viewModel.verificationControl?.status == .pending else {
                return
            }
            didFulfill = true
            snapshotArrived.fulfill()
        }

        await fulfillment(of: [snapshotArrived], timeout: 1)
        XCTAssertTrue(viewModel.visiblePendingItems.isEmpty)
        XCTAssertEqual(viewModel.contributionLine, "+16283095734")
    }

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
        return wireMessage(id: id, text: text, date: date, sender: sender)
    }

    private func wireMessage(
        id: String,
        text: String,
        date: TimeInterval,
        sender: ConversationMember
    ) -> AnyMessage {
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

    func publish(_ messages: [AnyMessage]) {
        subject.send(messages)
    }
}
