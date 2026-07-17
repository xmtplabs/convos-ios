import Combine
@testable import Convos
import ConvosConnections
import ConvosCore
import XCTest

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

    func testIncludeInfoPersistedWhenDraftBecomesRealConversation() async throws {
        GlobalConvoDefaults.shared.includeInfoWithInvites = true

        let draftConversation = Conversation.mock(id: "draft-info-test")
        let draftRepository = TestDraftConversationRepository(conversation: draftConversation)
        let metadataWriter = MockConversationMetadataWriter()
        let stateManager = MockConversationStateManager(
            draftConversationRepository: draftRepository,
            conversationMetadataWriter: metadataWriter
        )
        let messagingService = MockMessagingService(conversationStateManager: stateManager)

        let viewModel = ConversationViewModel(
            conversation: draftConversation,
            session: MockInboxesService(),
            messagingService: messagingService,
            conversationStateManager: stateManager,
            applyGlobalDefaultsForNewConversation: true
        )

        XCTAssertTrue(viewModel.includeInfoInPublicPreview)

        draftRepository.updateConversation(.mock(id: "real-info-test", name: "Real"))
        try await Task.sleep(for: .milliseconds(100))

        let includeInfoUpdate = metadataWriter.updatedIncludeInfoInPublicPreview.first {
            $0.conversationId == "real-info-test"
        }
        XCTAssertNotNil(includeInfoUpdate)
        XCTAssertEqual(includeInfoUpdate?.enabled, true)
        withExtendedLifetime(viewModel) {}
    }
}

private final class TestDraftConversationRepository: DraftConversationRepositoryProtocol, @unchecked Sendable {
    private let conversationSubject: CurrentValueSubject<Conversation?, Never>

    init(conversation: Conversation) {
        conversationSubject = CurrentValueSubject(conversation)
    }

    var conversationId: String {
        conversationSubject.value?.id ?? ""
    }

    var messagesRepository: any MessagesRepositoryProtocol {
        MockMessagesRepository(conversationId: conversationId)
    }

    var myProfileRepository: any MyProfileRepositoryProtocol {
        MockMyProfileRepository()
    }

    var conversationPublisher: AnyPublisher<Conversation?, Never> {
        conversationSubject.eraseToAnyPublisher()
    }

    func fetchConversation() throws -> Conversation? {
        conversationSubject.value
    }

    func updateConversation(_ conversation: Conversation) {
        conversationSubject.send(conversation)
    }
}
