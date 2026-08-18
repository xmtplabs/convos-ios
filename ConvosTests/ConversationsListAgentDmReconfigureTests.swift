@testable import Convos
import ConvosCore
import XCTest

/// The conversations list is a diffable collection view whose item identity is
/// the conversation id alone, so applying a snapshot never refreshes a row that
/// kept its id. `changedConversationIds` drives the follow-up
/// `reconfigureItems`, which makes it the only thing that updates a visible
/// row's content. Every field the row renders has to be compared there.
@MainActor
final class ConversationsListAgentDmReconfigureTests: XCTestCase {
    func testAgentDmReplyMarksRowChanged() {
        let before = Conversation.mock(id: "convo-1")
        var after = before
        after.agentDm = agentDmSummary(text: "Hey Jarod!")

        let changed = changedIds(old: before, new: after)

        XCTAssertTrue(changed.contains("convo-1"))
    }

    func testNewAgentDmMessageMarksRowChanged() {
        var before = Conversation.mock(id: "convo-1")
        before.agentDm = agentDmSummary(text: "Hey Jarod!")
        var after = before
        after.agentDm = agentDmSummary(text: "Still around?")

        let changed = changedIds(old: before, new: after)

        XCTAssertTrue(changed.contains("convo-1"))
    }

    func testAgentDmReadStateMarksRowChanged() {
        var before = Conversation.mock(id: "convo-1")
        before.agentDm = agentDmSummary(text: "Hey Jarod!", isUnread: true)
        var after = before
        after.agentDm = agentDmSummary(text: "Hey Jarod!", isUnread: false)

        let changed = changedIds(old: before, new: after)

        XCTAssertTrue(changed.contains("convo-1"))
    }

    /// Guards the premise: the comparison is a filter, not a pass-through, so a
    /// row that did not change must not be reconfigured.
    func testUnchangedConversationIsNotMarkedChanged() {
        var conversation = Conversation.mock(id: "convo-1")
        conversation.agentDm = agentDmSummary(text: "Hey Jarod!")

        let changed = changedIds(old: conversation, new: conversation)

        XCTAssertTrue(changed.isEmpty)
    }

    // MARK: - Helpers

    private func changedIds(old: Conversation, new: Conversation) -> Set<String> {
        let viewController = ConversationsViewController()
        return viewController.changedConversationIds(
            old: state(with: old),
            new: state(with: new),
            selectionChanged: false
        )
    }

    private func state(with conversation: Conversation) -> ConversationsViewController.State {
        var state = ConversationsViewController.State.empty
        state.unpinnedConversations = [conversation]
        return state
    }

    /// `MessagePreview` has no public initializer, so a mock conversation
    /// supplies one.
    private func agentDmSummary(text: String, isUnread: Bool = true) -> Conversation.AgentDmSummary {
        let preview = Conversation.mock(isUnread: true, lastMessageText: text).lastMessage
        return Conversation.AgentDmSummary(
            inboxId: "agent-inbox",
            displayName: "Jarod's agent",
            lastMessage: preview,
            isUnread: isUnread
        )
    }
}
