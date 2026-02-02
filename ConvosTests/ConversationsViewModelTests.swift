import XCTest
@testable import Convos
import ConvosCore

@MainActor
final class ConversationsViewModelTests: XCTestCase {
    // MARK: - memory leak bug identified
    func testSelectedConversation_leaksWhenWriterCreationNeverCompletes() async {
        // ARRANGE
        let conversation = Conversation.mock(id: "convo-1", clientId: "client-1", inboxId: "inbox-1")
        let conversationsRepo = MockConversationsRepository(conversations: [conversation])
        let countRepo = MockConversationsCountRepository(count: 1)

        let messagingService = MockMessagingService()
        let secondCallExpectation = expectation(description: "messagingService called for writer creation")
        var messagingServiceCallCount = 0
        let session = MockInboxesService(
            conversationsRepository: conversationsRepo,
            conversationsCountRepository: countRepo,
            messagingServiceHandler: { _, _ in
                messagingServiceCallCount += 1
                if messagingServiceCallCount == 2 {
                    secondCallExpectation.fulfill()
                    // Second call is used by getOrCreateWriter in markConversationAsRead
                    // Simulate a never-ending call (e.g., a hung SDK/network).
                    _ = try await withCheckedThrowingContinuation { (_: CheckedContinuation<AnyMessagingService, Error>) in }
                }
                // First call is used by ConversationViewModel.create
                return messagingService
            }
        )

        var viewModel: ConversationsViewModel? = ConversationsViewModel(session: session)
        weak var weakViewModel = viewModel

        // ACT
        viewModel?.selectedConversationId = conversation.id
        await fulfillment(of: [secondCallExpectation], timeout: 1.0)

        viewModel = nil
        try? await Task.sleep(for: .milliseconds(50))

        // ASSERT
        XCTAssertNil(
            weakViewModel,
            "Expected ConversationsViewModel to deinit once released, " +
            "but it remains alive due to a retained pending writer Task (retain cycle)."
        )
    }
}
