@testable import Convos
import ConvosConnections
import ConvosCore
import XCTest

@MainActor
final class ConversationsViewModelTabSelectionTests: XCTestCase {
    func testSelectAgentDmSetsAgentTabOverride() {
        let conversation = Conversation.mock(id: "conv-agent", name: "Agent convo")
        let viewModel = makeViewModel(with: [conversation])

        viewModel.selectAgentDm(conversation)

        XCTAssertEqual(viewModel.selectedInitialTab, .agent)
        XCTAssertNil(viewModel.selectedInitialAgentDmInboxId,
                     "Open Agent DM drives the tab via the override, not the folded-in DM inbox id")
        XCTAssertEqual(viewModel.selectedConversationId, conversation.id)
    }

    func testSelectThingsSetsContextTabOverride() {
        let conversation = Conversation.mock(id: "conv-things", name: "Things convo")
        let viewModel = makeViewModel(with: [conversation])

        viewModel.selectThings(conversation)

        XCTAssertEqual(viewModel.selectedInitialTab, .context)
        XCTAssertNil(viewModel.selectedInitialAgentDmInboxId)
        XCTAssertEqual(viewModel.selectedConversationId, conversation.id)
    }

    func testNormalSelectClearsPriorTabOverride() {
        let agentConversation = Conversation.mock(id: "conv-a", name: "A")
        let groupConversation = Conversation.mock(id: "conv-b", name: "B")
        let viewModel = makeViewModel(with: [agentConversation, groupConversation])

        viewModel.selectThings(agentConversation)
        XCTAssertEqual(viewModel.selectedInitialTab, .context)

        viewModel.select(groupConversation)

        XCTAssertNil(viewModel.selectedInitialTab,
                     "A normal tap must not inherit a prior Open Things/Agent override")
        XCTAssertEqual(viewModel.selectedConversationId, groupConversation.id)
    }

    func testDismissingSessionClearsTabOverride() {
        let conversation = Conversation.mock(id: "conv-dismiss", name: "Dismiss")
        let viewModel = makeViewModel(with: [conversation])

        viewModel.selectThings(conversation)
        XCTAssertEqual(viewModel.selectedInitialTab, .context)
        XCTAssertNotNil(viewModel.selectedConversationViewModel)

        viewModel.selectedConversationId = nil

        XCTAssertNil(viewModel.selectedInitialTab,
                     "Ending an open session resets the per-open tab override")
        XCTAssertNil(viewModel.selectedInitialAgentDmInboxId)
    }

    func testNormalSelectMarksGroupRead() async throws {
        let localStateWriter = MockConversationLocalStateWriter()
        let conversation = Conversation.mock(id: "conv-read", name: "Read me")
        let viewModel = makeViewModel(with: [conversation], localStateWriter: localStateWriter)

        viewModel.select(conversation)

        try await waitUntilMainActor(timeout: 1.0) {
            localStateWriter.unreadStates[conversation.id] == false
        }
        XCTAssertEqual(localStateWriter.unreadStates[conversation.id], false,
                       "Opening on the Group tab clears the group's unread")
    }

    func testOpenThingsDoesNotMarkGroupRead() async throws {
        let localStateWriter = MockConversationLocalStateWriter()
        let conversation = Conversation.mock(id: "conv-things-unread", name: "Keep unread")
        let viewModel = makeViewModel(with: [conversation], localStateWriter: localStateWriter)

        viewModel.selectThings(conversation)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(localStateWriter.unreadStates[conversation.id],
                     "Opening the Things tab must leave the Group lane's unread untouched")
    }

    func testOpenAgentDmDoesNotMarkGroupRead() async throws {
        let localStateWriter = MockConversationLocalStateWriter()
        let conversation = Conversation.mock(id: "conv-agent-unread", name: "Keep unread")
        let viewModel = makeViewModel(with: [conversation], localStateWriter: localStateWriter)

        viewModel.selectAgentDm(conversation)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(localStateWriter.unreadStates[conversation.id],
                     "Opening the Agent DM tab must leave the Group lane's unread untouched")
    }

    // MARK: - Helpers

    private func makeViewModel(
        with conversations: [Conversation],
        localStateWriter: MockConversationLocalStateWriter = MockConversationLocalStateWriter()
    ) -> ConversationsViewModel {
        let messagingService = MockMessagingService(conversationLocalStateWriter: localStateWriter)
        let session = MockInboxesService(mockMessagingService: messagingService)
        let viewModel = ConversationsViewModel(session: session)
        viewModel.conversations = conversations
        return viewModel
    }

    private func waitUntilMainActor(
        timeout: TimeInterval,
        interval: TimeInterval = 0.02,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        XCTFail("waitUntilMainActor timed out after \(timeout)s")
    }
}
