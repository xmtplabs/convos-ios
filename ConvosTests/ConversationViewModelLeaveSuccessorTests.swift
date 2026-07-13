@testable import Convos
import ConvosCore
import XCTest

/// Coverage for the successor-candidate selection feeding
/// `ConversationLeaveWriter`: `leaveGroupConvo()` must not offer optimistic
/// agent sentinels as super-admin successors. Those members are
/// presentation-only overlays shown while agent instances provision; their
/// inbox ids don't exist on the network, so promoting one would fail and
/// abort the leave.
@MainActor
final class ConversationViewModelLeaveSuccessorTests: XCTestCase {
    func testLeaveExcludesOptimisticAgentMembersFromSuccessors() async throws {
        let human = ConversationMember.mock(isCurrentUser: false, name: "Alice")
        let sentinel = ConversationMember(
            profile: .mock(
                inboxId: AgentShareInfo.optimisticInboxIdPrefix + "template-1",
                name: "Pending Agent"
            ),
            role: .member,
            isCurrentUser: false,
            isAgent: true
        )
        XCTAssertTrue(sentinel.isOptimisticAgentMember)

        let group = Conversation.mock(
            id: "test-group",
            members: [.mock(isCurrentUser: true), human, sentinel]
        )
        XCTAssertEqual(group.kind, .group)

        let leaveWriter = MockConversationLeaveWriter()
        let viewModel = ConversationViewModel(
            conversation: group,
            session: MockInboxesService(),
            messagingService: MockMessagingService(conversationLeaveWriter: leaveWriter),
            applyGlobalDefaultsForNewConversation: false
        )

        viewModel.leaveGroupConvo()

        // leaveGroupConvo performs the leave in a detached task; poll until
        // the mock records it.
        for _ in 0..<100 where leaveWriter.leftConversations.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let record = try XCTUnwrap(leaveWriter.leftConversations.first)
        XCTAssertEqual(record.successorCandidates.map(\.inboxId),
                       [human.profile.inboxId],
                       "Only real members may be offered as super-admin successors")
    }
}
