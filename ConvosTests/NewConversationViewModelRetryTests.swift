import Combine
import ConvosCore
import XCTest
@testable import Convos

@MainActor
final class NewConversationViewModelRetryTests: XCTestCase {

    // MARK: - Inbox cleanup on discard

    func testCleanUpDeletesInboxWhenNotReady() async {
        let session = SpySessionManager()
        let draftConvo = Conversation.mock(id: "draft-test", clientId: "test-client-1")
        let draftRepo = MockDraftConversationRepository(conversation: draftConvo)
        let stateManager = MockConversationStateManager(
            conversationId: "draft-test",
            draftConversationRepository: draftRepo
        )
        let inboxStateManager = MockInboxStateManager(
            initialState: .idle(clientId: "test-client-1")
        )
        let messagingService = MockMessagingService(
            inboxStateManager: inboxStateManager,
            conversationStateManager: stateManager
        )

        let vm = NewConversationViewModel(
            session: session,
            messagingService: messagingService,
            autoCreateConversation: false
        )

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.conversationViewModel?.conversation.clientId, "test-client-1")

        stateManager.setState(.error(TestError.networkUnavailable))
        await Task.yield()

        vm.cleanUpIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(session.deleteInboxCallCount, 1)
        XCTAssertEqual(session.lastDeletedClientId, "test-client-1")
    }

    func testCleanUpDoesNotDeleteInboxWhenReady() async {
        let session = SpySessionManager()
        let stateManager = MockConversationStateManager(conversationId: "draft-test")
        let messagingService = MockMessagingService(conversationStateManager: stateManager)

        let vm = NewConversationViewModel(
            session: session,
            messagingService: messagingService,
            autoCreateConversation: false
        )

        try? await stateManager.createConversation()
        try? await Task.sleep(for: .milliseconds(50))

        vm.cleanUpIfNeeded()

        XCTAssertEqual(session.deleteInboxCallCount, 0)
    }

    func testCleanUpIsIdempotent() async {
        let session = SpySessionManager()
        let stateManager = MockConversationStateManager(conversationId: "draft-test")
        let messagingService = MockMessagingService(conversationStateManager: stateManager)

        let vm = NewConversationViewModel(
            session: session,
            messagingService: messagingService,
            autoCreateConversation: false
        )

        stateManager.setState(.error(TestError.networkUnavailable))
        await Task.yield()

        vm.cleanUpIfNeeded()
        vm.cleanUpIfNeeded()
        vm.cleanUpIfNeeded()
        await session.waitForDeleteInbox()

        XCTAssertEqual(session.deleteInboxCallCount, 1)
    }

    func testDismissWithDeletionPreventsDoubleCleanUp() async {
        let session = SpySessionManager()
        let stateManager = MockConversationStateManager(conversationId: "draft-test")
        let messagingService = MockMessagingService(conversationStateManager: stateManager)

        let vm = NewConversationViewModel(
            session: session,
            messagingService: messagingService,
            autoCreateConversation: false
        )

        stateManager.setState(.error(TestError.networkUnavailable))
        await Task.yield()

        vm.dismissWithDeletion()
        vm.cleanUpIfNeeded()
        await session.waitForDeleteInbox()

        XCTAssertEqual(session.deleteInboxCallCount, 1)
    }

    // MARK: - Error classification

    func testDnsErrorClassifiedAsServiceUnavailable() {
        let error = ConversationStateMachineError.stateMachineError(
            FakeXMTPError(message: "[GroupError::Client] Group error: client: API error: service is currently unavailable, self: \"dns error\"")
        )
        XCTAssertEqual(error.networkErrorKind, .serviceUnavailable)
        XCTAssertEqual(error.title, "Can't connect")
    }

    func testTimeoutErrorClassified() {
        let error = ConversationStateMachineError.timedOut
        XCTAssertEqual(error.networkErrorKind, .timedOut)
        XCTAssertEqual(error.title, "Connection timed out")
        XCTAssertEqual(error.description, "The server took too long to respond. Try again in a moment.")
    }

    func testConnectionLostClassified() {
        let error = ConversationStateMachineError.stateMachineError(
            FakeXMTPError(message: "The network connection was lost.")
        )
        XCTAssertEqual(error.networkErrorKind, .connectionLost)
        XCTAssertEqual(error.title, "No connection")
    }

    func testTLSErrorClassified() {
        let error = ConversationStateMachineError.stateMachineError(
            FakeXMTPError(message: "A TLS error caused the secure connection to fail.")
        )
        XCTAssertEqual(error.networkErrorKind, .tlsFailure)
        XCTAssertEqual(error.title, "Secure connection failed")
    }

    func testStorageErrorClassifiedAsInternal() {
        let error = ConversationStateMachineError.stateMachineError(
            FakeXMTPError(message: "[GroupError::Storage] Group error: storage error: Pool needs to reconnect before use")
        )
        XCTAssertEqual(error.networkErrorKind, .internalError)
        XCTAssertEqual(error.title, "Something went wrong")
    }

    func testUnknownErrorHasNoNetworkKind() {
        let error = ConversationStateMachineError.stateMachineError(
            FakeXMTPError(message: "Some completely unknown error")
        )
        XCTAssertNil(error.networkErrorKind)
        XCTAssertEqual(error.title, "Something went wrong")
    }

    func testNonNetworkErrorsPreserveExistingCopy() {
        XCTAssertEqual(ConversationStateMachineError.inviteExpired.title, "Invite expired")
        XCTAssertEqual(ConversationStateMachineError.conversationExpired.title, "Convo expired")
        XCTAssertEqual(ConversationStateMachineError.failedFindingConversation.title, "No convo here")
        XCTAssertEqual(ConversationStateMachineError.failedVerifyingSignature.title, "Invalid invite")
        XCTAssertEqual(ConversationStateMachineError.invalidInviteCodeFormat("bad").title, "Invalid code")
    }

}

// MARK: - Test helpers

private enum TestError: Error {
    case networkUnavailable
}

private struct FakeXMTPError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private final class SpySessionManager: SessionManagerProtocol, @unchecked Sendable {
    private let base: MockInboxesService = MockInboxesService()
    private(set) var deleteInboxCallCount: Int = 0
    private(set) var lastDeletedClientId: String?
    private var deleteInboxContinuation: CheckedContinuation<Void, Never>?

    func waitForDeleteInbox() async {
        if deleteInboxCallCount > 0 { return }
        await withCheckedContinuation { continuation in
            deleteInboxContinuation = continuation
        }
    }

    func addInbox() async -> (service: AnyMessagingService, conversationId: String?) { await base.addInbox() }
    func addInboxOnly() async -> AnyMessagingService { await base.addInboxOnly() }

    func deleteInbox(clientId: String, inboxId: String) async throws {
        deleteInboxCallCount += 1
        lastDeletedClientId = clientId
        deleteInboxContinuation?.resume()
        deleteInboxContinuation = nil
    }

    func deleteAllInboxes() async throws { try await base.deleteAllInboxes() }
    func deleteAllInboxesWithProgress() -> AsyncThrowingStream<InboxDeletionProgress, Error> { base.deleteAllInboxesWithProgress() }
    func messagingService(for clientId: String, inboxId: String) async throws -> AnyMessagingService { try await base.messagingService(for: clientId, inboxId: inboxId) }
    func messagingServiceSync(for clientId: String, inboxId: String) -> AnyMessagingService { base.messagingServiceSync(for: clientId, inboxId: inboxId) }
    func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol { base.conversationsRepository(for: consent) }
    func conversationsCountRepo(for consent: [Consent], kinds: [ConversationKind]) -> any ConversationsCountRepositoryProtocol { base.conversationsCountRepo(for: consent, kinds: kinds) }
    func pinnedConversationsCountRepo() -> any PinnedConversationsCountRepositoryProtocol { base.pinnedConversationsCountRepo() }
    func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol { base.inviteRepository(for: conversationId) }
    func conversationRepository(for conversationId: String, inboxId: String, clientId: String) async throws -> any ConversationRepositoryProtocol { try await base.conversationRepository(for: conversationId, inboxId: inboxId, clientId: clientId) }
    func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol { base.messagesRepository(for: conversationId) }
    func photoPreferencesRepository(for conversationId: String) -> any PhotoPreferencesRepositoryProtocol { base.photoPreferencesRepository(for: conversationId) }
    func photoPreferencesWriter() -> any PhotoPreferencesWriterProtocol { base.photoPreferencesWriter() }
    func attachmentLocalStateWriter() -> any AttachmentLocalStateWriterProtocol { base.attachmentLocalStateWriter() }
    func setActiveClientId(_ clientId: String?) async { await base.setActiveClientId(clientId) }
    func wakeInboxForNotification(clientId: String, inboxId: String) async { await base.wakeInboxForNotification(clientId: clientId, inboxId: inboxId) }
    func wakeInboxForNotification(conversationId: String) async { await base.wakeInboxForNotification(conversationId: conversationId) }
    func isInboxAwake(clientId: String) async -> Bool { await base.isInboxAwake(clientId: clientId) }
    func isInboxSleeping(clientId: String) async -> Bool { await base.isInboxSleeping(clientId: clientId) }
    func shouldDisplayNotification(for conversationId: String) async -> Bool { await base.shouldDisplayNotification(for: conversationId) }
    func notifyChangesInDatabase() { base.notifyChangesInDatabase() }
    func inboxId(for conversationId: String) async -> String? { await base.inboxId(for: conversationId) }
    func requestAgentJoin(slug: String, instructions: String, forceErrorCode: Int?) async throws -> ConvosAPI.AgentJoinResponse { try await base.requestAgentJoin(slug: slug, instructions: instructions, forceErrorCode: forceErrorCode) }
    func pendingInviteDetails() throws -> [PendingInviteDetail] { try base.pendingInviteDetails() }
    func deleteExpiredPendingInvites() async throws -> Int { try await base.deleteExpiredPendingInvites() }
    func orphanedInboxDetails() throws -> [OrphanedInboxDetail] { try base.orphanedInboxDetails() }
    func deleteOrphanedInbox(clientId: String, inboxId: String) async throws { try await base.deleteOrphanedInbox(clientId: clientId, inboxId: inboxId) }
    func makeAssetRenewalManager() async -> AssetRenewalManager { await base.makeAssetRenewalManager() }
}
