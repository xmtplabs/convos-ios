@testable import Convos
import ConvosCore
import XCTest

/// Coverage for the leave affordance gating: `canLeaveConversation` limits
/// the Leave section in the conversation info view to group conversations.
/// Self-removal is a group-only operation -- the protocol rejects leaving a
/// DM -- so the affordance must never be offered there.
@MainActor
final class ConversationViewModelLeaveTests: XCTestCase {
    func testCanLeaveConversationFalseForDM() {
        // Conversation.mock derives kind == .dm from a two-member roster.
        let dm = Conversation.mock(
            id: "test-dm",
            members: [
                .mock(isCurrentUser: true),
                .mock(isCurrentUser: false, name: "Alice"),
            ]
        )
        XCTAssertEqual(dm.kind, .dm)

        let viewModel = makeViewModel(conversation: dm)
        XCTAssertFalse(viewModel.canLeaveConversation,
                       "The Leave affordance must not be offered for a DM")
    }

    func testCanLeaveConversationTrueForGroup() {
        let group = Conversation.mock(
            id: "test-group",
            members: [
                .mock(isCurrentUser: true),
                .mock(isCurrentUser: false, name: "Alice"),
                .mock(isCurrentUser: false, name: "Bob"),
            ]
        )
        XCTAssertEqual(group.kind, .group)

        let viewModel = makeViewModel(conversation: group)
        XCTAssertTrue(viewModel.canLeaveConversation)
    }

    // MARK: - Helpers

    private func makeViewModel(conversation: Conversation) -> ConversationViewModel {
        ConversationViewModel(
            conversation: conversation,
            session: MockInboxesService(),
            messagingService: MockMessagingService(),
            applyGlobalDefaultsForNewConversation: false
        )
    }
}
