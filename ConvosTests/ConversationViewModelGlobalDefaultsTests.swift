import Combine
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

    func testRevealPreferenceSeededWhenDraftBecomesRealConversation() async throws {
        GlobalConvoDefaults.shared.revealModeEnabled = false

        let draftConversation = Conversation.mock(id: "draft-seed-test")
        let draftRepository = TestDraftConversationRepository(conversation: draftConversation)
        let stateManager = MockConversationStateManager(draftConversationRepository: draftRepository)
        let messagingService = MockMessagingService(conversationStateManager: stateManager)

        let photoPreferencesRepository = MockPhotoPreferencesRepository(preferences: nil)
        let photoPreferencesWriter = MockPhotoPreferencesWriter()
        let session = TestSessionManager(
            base: MockInboxesService(),
            photoPreferencesRepository: photoPreferencesRepository,
            photoPreferencesWriter: photoPreferencesWriter
        )

        let viewModel = ConversationViewModel(
            conversation: draftConversation,
            session: session,
            messagingService: messagingService,
            conversationStateManager: stateManager,
            applyGlobalDefaultsForNewConversation: true
        )

        draftRepository.updateConversation(.mock(id: "real-seed-test", name: "Real"))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(photoPreferencesWriter.autoRevealValues["real-seed-test"], true)
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

private final class TestSessionManager: SessionManagerProtocol, @unchecked Sendable {
    private let base: MockInboxesService
    private let customPhotoPreferencesRepository: MockPhotoPreferencesRepository
    private let customPhotoPreferencesWriter: MockPhotoPreferencesWriter

    init(
        base: MockInboxesService,
        photoPreferencesRepository: MockPhotoPreferencesRepository,
        photoPreferencesWriter: MockPhotoPreferencesWriter
    ) {
        self.base = base
        customPhotoPreferencesRepository = photoPreferencesRepository
        customPhotoPreferencesWriter = photoPreferencesWriter
    }

    func addInbox() async -> (service: AnyMessagingService, conversationId: String?) {
        await base.addInbox()
    }

    func addInboxOnly() async -> AnyMessagingService {
        await base.addInboxOnly()
    }

    func deleteInbox(clientId: String, inboxId: String) async throws {
        try await base.deleteInbox(clientId: clientId, inboxId: inboxId)
    }

    func deleteAllInboxes() async throws {
        try await base.deleteAllInboxes()
    }

    func deleteAllInboxesWithProgress() -> AsyncThrowingStream<InboxDeletionProgress, Error> {
        base.deleteAllInboxesWithProgress()
    }

    func messagingService(for clientId: String, inboxId: String) async throws -> AnyMessagingService {
        try await base.messagingService(for: clientId, inboxId: inboxId)
    }

    func messagingServiceSync(for clientId: String, inboxId: String) -> AnyMessagingService {
        base.messagingServiceSync(for: clientId, inboxId: inboxId)
    }

    func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol {
        base.inviteRepository(for: conversationId)
    }

    func conversationRepository(for conversationId: String, inboxId: String, clientId: String) async throws -> any ConversationRepositoryProtocol {
        try await base.conversationRepository(for: conversationId, inboxId: inboxId, clientId: clientId)
    }

    func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol {
        base.messagesRepository(for: conversationId)
    }

    func photoPreferencesRepository(for conversationId: String) -> any PhotoPreferencesRepositoryProtocol {
        customPhotoPreferencesRepository
    }

    func photoPreferencesWriter() -> any PhotoPreferencesWriterProtocol {
        customPhotoPreferencesWriter
    }

    func attachmentLocalStateWriter() -> any AttachmentLocalStateWriterProtocol {
        base.attachmentLocalStateWriter()
    }

    func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol {
        base.conversationsRepository(for: consent)
    }

    func conversationsCountRepo(for consent: [Consent], kinds: [ConversationKind]) -> any ConversationsCountRepositoryProtocol {
        base.conversationsCountRepo(for: consent, kinds: kinds)
    }

    func pinnedConversationsCountRepo() -> any PinnedConversationsCountRepositoryProtocol {
        base.pinnedConversationsCountRepo()
    }

    func notifyChangesInDatabase() {
        base.notifyChangesInDatabase()
    }

    func shouldDisplayNotification(for conversationId: String) async -> Bool {
        await base.shouldDisplayNotification(for: conversationId)
    }

    func setActiveClientId(_ clientId: String?) async {
        await base.setActiveClientId(clientId)
    }

    func wakeInboxForNotification(clientId: String, inboxId: String) async {
        await base.wakeInboxForNotification(clientId: clientId, inboxId: inboxId)
    }

    func wakeInboxForNotification(conversationId: String) async {
        await base.wakeInboxForNotification(conversationId: conversationId)
    }

    func isInboxAwake(clientId: String) async -> Bool {
        await base.isInboxAwake(clientId: clientId)
    }

    func isInboxSleeping(clientId: String) async -> Bool {
        await base.isInboxSleeping(clientId: clientId)
    }

    func inboxId(for conversationId: String) async -> String? {
        await base.inboxId(for: conversationId)
    }
}
