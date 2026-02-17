import XCTest
import ConvosCore
@testable import Convos

@MainActor
final class ConversationViewModelGlobalDefaultsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalConvoDefaults.shared.reset()
    }

    override func tearDown() {
        GlobalConvoDefaults.shared.reset()
        super.tearDown()
    }

    func testDraftConversationSeedsIncludeInfoFromGlobalDefaults() {
        GlobalConvoDefaults.shared.includeInfoWithInvites = true

        let viewModel = ConversationViewModel(
            conversation: .mock(id: "draft-test-conversation"),
            session: MockInboxesService(),
            messagingService: MockMessagingService(),
            applyGlobalDefaultsForNewConversation: true
        )

        XCTAssertTrue(viewModel.includeInfoInPublicPreview)
    }

    func testNonDraftConversationDoesNotApplyDraftIncludeInfoSeeding() {
        GlobalConvoDefaults.shared.includeInfoWithInvites = true

        let viewModel = ConversationViewModel(
            conversation: .mock(id: "real-test-conversation", name: "Real"),
            session: MockInboxesService(),
            messagingService: MockMessagingService(),
            applyGlobalDefaultsForNewConversation: true
        )

        XCTAssertFalse(viewModel.includeInfoInPublicPreview)
    }
}
