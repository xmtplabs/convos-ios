import ConvosCore
import XCTest
@testable import Convos

@MainActor
final class ConversationsViewModelDeleteTests: XCTestCase {
    func testLeaveRoutesThroughConsentWriter() async throws {
        let conversation = Conversation.mock(id: "conv-to-delete", name: "Test")
        let consentWriter = MockConversationConsentWriter()
        let messagingService = MockMessagingService(conversationConsentWriter: consentWriter)
        let session = TestSessionManager(
            base: MockInboxesService(),
            messagingService: messagingService
        )

        let viewModel = ConversationsViewModel(session: session)
        viewModel.conversations = [conversation]

        viewModel.leave(conversation: conversation)

        XCTAssertFalse(viewModel.conversations.contains(conversation),
                       "Row should be hidden optimistically before the writer finishes")

        try await waitUntil(timeout: 1.0) {
            !consentWriter.deletedConversations.isEmpty
        }

        XCTAssertEqual(consentWriter.deletedConversations.map(\.id), [conversation.id])
    }

    func testLeaveSuccessRemovesFromHiddenConversationIds() async throws {
        let conversation = Conversation.mock(id: "conv-success", name: "Success")
        let consentWriter = MockConversationConsentWriter()
        let messagingService = MockMessagingService(conversationConsentWriter: consentWriter)
        let session = TestSessionManager(
            base: MockInboxesService(),
            messagingService: messagingService
        )

        let viewModel = ConversationsViewModel(session: session)
        viewModel.conversations = [conversation]

        viewModel.leave(conversation: conversation)

        try await waitUntil(timeout: 1.0) {
            !consentWriter.deletedConversations.isEmpty
        }

        try await waitUntilMainActor(timeout: 1.0) {
            !viewModel.hiddenConversationIds.contains(conversation.id)
        }

        XCTAssertFalse(
            viewModel.hiddenConversationIds.contains(conversation.id),
            "Optimistic hide should be released once the consent write succeeds"
        )
    }

    func testLeaveFailureRemovesFromHiddenConversationIds() async throws {
        let conversation = Conversation.mock(id: "conv-fail", name: "Failure")
        let consentWriter = MockConversationConsentWriter()
        consentWriter.deleteError = TestError.deleteFailed
        let messagingService = MockMessagingService(conversationConsentWriter: consentWriter)
        let session = TestSessionManager(
            base: MockInboxesService(),
            messagingService: messagingService
        )

        let viewModel = ConversationsViewModel(session: session)
        viewModel.conversations = [conversation]

        viewModel.leave(conversation: conversation)

        try await waitUntilMainActor(timeout: 1.0) {
            !viewModel.hiddenConversationIds.contains(conversation.id)
        }

        XCTAssertFalse(
            viewModel.hiddenConversationIds.contains(conversation.id),
            "Optimistic hide should be released when the consent write fails so the row can reappear"
        )
        XCTAssertTrue(
            consentWriter.deletedConversations.isEmpty,
            "Writer should not have recorded a successful deletion when throwing"
        )
    }

    func testLeaveHidesRowBeforeWriterCompletes() async throws {
        let slowWriter = DelayedConsentWriter()
        let messagingService = MockMessagingService(conversationConsentWriter: slowWriter)
        let session = TestSessionManager(
            base: MockInboxesService(),
            messagingService: messagingService
        )

        let conversation = Conversation.mock(id: "conv-delayed", name: "Delayed")
        let viewModel = ConversationsViewModel(session: session)
        viewModel.conversations = [conversation]

        viewModel.leave(conversation: conversation)

        XCTAssertTrue(
            viewModel.conversations.isEmpty,
            "Optimistic hide must happen before the writer resolves"
        )
        let beforeResume = await slowWriter.deletedConversations
        XCTAssertTrue(
            beforeResume.isEmpty,
            "Writer should not have been observed completing yet"
        )

        await slowWriter.resume()

        try await waitUntil(timeout: 1.0) {
            await !slowWriter.deletedConversations.isEmpty
        }
        let afterResume = await slowWriter.deletedConversations
        XCTAssertEqual(afterResume.map(\.id), [conversation.id])
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.02,
        condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        XCTFail("waitUntil timed out after \(timeout)s")
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

private enum TestError: Error {
    case deleteFailed
}

private actor DelayedConsentWriterState {
    private var _deletedConversations: [Conversation] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var released: Bool = false

    var deletedConversations: [Conversation] {
        _deletedConversations
    }

    func waitForGate() async {
        if released { return }
        await withCheckedContinuation { continuation in
            gate = continuation
        }
    }

    func recordDeletion(_ conversation: Conversation) {
        _deletedConversations.append(conversation)
    }

    func release() {
        released = true
        let pending = gate
        gate = nil
        pending?.resume()
    }
}

private final class DelayedConsentWriter: ConversationConsentWriterProtocol, @unchecked Sendable {
    private let state: DelayedConsentWriterState = DelayedConsentWriterState()

    var deletedConversations: [Conversation] {
        get async { await state.deletedConversations }
    }

    func join(conversation: Conversation) async throws {}

    func delete(conversation: Conversation) async throws {
        await state.waitForGate()
        await state.recordDeletion(conversation)
    }

    func deleteAll() async throws {}

    func resume() async {
        await state.release()
    }
}

private final class TestSessionManager: SessionManagerProtocol, @unchecked Sendable {
    private let base: MockInboxesService
    private let customMessagingService: any MessagingServiceProtocol

    init(
        base: MockInboxesService,
        messagingService: any MessagingServiceProtocol
    ) {
        self.base = base
        self.customMessagingService = messagingService
    }

    func prepareNewConversation() async -> (service: AnyMessagingService, conversationId: String?) {
        (service: customMessagingService, conversationId: nil)
    }

    func deleteAllInboxes() async throws {
        try await base.deleteAllInboxes()
    }

    func deleteAllInboxesWithProgress() -> AsyncThrowingStream<InboxDeletionProgress, Error> {
        base.deleteAllInboxesWithProgress()
    }

    func messagingService() -> AnyMessagingService {
        customMessagingService
    }

    func messagingServiceSync() -> AnyMessagingService {
        customMessagingService
    }

    func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol {
        base.inviteRepository(for: conversationId)
    }

    func conversationRepository(for conversationId: String) -> any ConversationRepositoryProtocol {
        base.conversationRepository(for: conversationId)
    }

    func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol {
        base.messagesRepository(for: conversationId)
    }

    func photoPreferencesRepository(for conversationId: String) -> any PhotoPreferencesRepositoryProtocol {
        base.photoPreferencesRepository(for: conversationId)
    }

    func photoPreferencesWriter() -> any PhotoPreferencesWriterProtocol {
        base.photoPreferencesWriter()
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

    func setIsOnConversationsList(_ isOn: Bool) {
        base.setIsOnConversationsList(isOn)
    }

    func wakeInboxForNotification(conversationId: String) {
        base.wakeInboxForNotification(conversationId: conversationId)
    }

    func inboxId(for conversationId: String) async -> String? {
        await base.inboxId(for: conversationId)
    }

    func requestAgentJoin(slug: String, instructions: String, forceErrorCode: Int? = nil) async throws -> ConvosAPI.AgentJoinResponse {
        try await base.requestAgentJoin(slug: slug, instructions: instructions, forceErrorCode: forceErrorCode)
    }

    func redeemInviteCode(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        try await base.redeemInviteCode(code)
    }

    func fetchInviteCodeStatus(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        try await base.fetchInviteCodeStatus(code)
    }

    func voiceMemoTranscriptRepository() -> any VoiceMemoTranscriptRepositoryProtocol {
        base.voiceMemoTranscriptRepository()
    }

    func voiceMemoTranscriptWriter() -> any VoiceMemoTranscriptWriterProtocol {
        base.voiceMemoTranscriptWriter()
    }

    func voiceMemoTranscriptionService() -> any VoiceMemoTranscriptionServicing {
        base.voiceMemoTranscriptionService()
    }

    func assistantFilesLinksRepository(for conversationId: String) -> AssistantFilesLinksRepository {
        base.assistantFilesLinksRepository(for: conversationId)
    }

    func pendingInviteDetails() throws -> [PendingInviteDetail] {
        try base.pendingInviteDetails()
    }

    func deleteExpiredPendingInvites() async throws -> Int {
        try await base.deleteExpiredPendingInvites()
    }

    func isAccountOrphaned() throws -> Bool {
        try base.isAccountOrphaned()
    }

    func makeAssetRenewalManager() async -> AssetRenewalManager {
        await base.makeAssetRenewalManager()
    }

    func cloudConnectionManager(callbackURLScheme: String) -> any CloudConnectionManagerProtocol {
        base.cloudConnectionManager(callbackURLScheme: callbackURLScheme)
    }

    func cloudConnectionRepository() -> any CloudConnectionRepositoryProtocol {
        base.cloudConnectionRepository()
    }

    func capabilityProviderRegistry() -> any CapabilityProviderRegistry {
        base.capabilityProviderRegistry()
    }

    func capabilityResolver() -> any CapabilityResolver {
        base.capabilityResolver()
    }

    func capabilityRequestRepository(for conversationId: String) -> any CapabilityRequestRepositoryProtocol {
        base.capabilityRequestRepository(for: conversationId)
    }

    func deviceConnectionAuthorizer() -> any DeviceConnectionAuthorizer {
        base.deviceConnectionAuthorizer()
    }

    func capabilityResolutionsRepository(for conversationId: String) -> any CapabilityResolutionsRepositoryProtocol {
        base.capabilityResolutionsRepository(for: conversationId)
    }
}
