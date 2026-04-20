import Combine
import Foundation
import GRDB

public final class MockInboxesService: SessionManagerProtocol {
    private let mockMessagingService: MockMessagingService = MockMessagingService()

    public func deleteAllInboxesWithProgress() -> AsyncThrowingStream<InboxDeletionProgress, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Simulate deletion progress
                continuation.yield(.clearingDeviceRegistration)
                try? await Task.sleep(for: .milliseconds(200))
                // Simulate stopping 1 service
                continuation.yield(.stoppingServices(completed: 0, total: 1))
                try? await Task.sleep(for: .milliseconds(300))
                continuation.yield(.stoppingServices(completed: 1, total: 1))
                try? await Task.sleep(for: .milliseconds(200))
                continuation.yield(.deletingFromDatabase)
                try? await Task.sleep(for: .milliseconds(200))
                continuation.yield(.completed)
                continuation.finish()
            }
        }
    }

    public func shouldDisplayNotification(for conversationId: String) async -> Bool {
        true
    }

    public func notifyChangesInDatabase() {
    }

    public func inboxId(for conversationId: String) async -> String? {
        "mock-inbox-id"
    }

    public init() {
    }

    // MARK: - Inbox Management

    public func addInbox() async -> (service: AnyMessagingService, conversationId: String?) {
        (service: mockMessagingService, conversationId: nil)
    }

    public func addInboxOnly() async -> AnyMessagingService {
        mockMessagingService
    }

    public func deleteInbox(clientId: String, inboxId: String) async throws {
    }

    public func deleteAllInboxes() async throws {
    }

    // MARK: - Messaging Services

    public func messagingService(for clientId: String, inboxId: String) async throws -> AnyMessagingService {
        mockMessagingService
    }

    public func messagingServiceSync(for clientId: String, inboxId: String) -> AnyMessagingService {
        mockMessagingService
    }

    // MARK: - Factory methods for repositories

    public func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol {
        MockConversationsRepository()
    }

    public func conversationsCountRepo(for consent: [Consent], kinds: [ConversationKind]) -> any ConversationsCountRepositoryProtocol {
        MockConversationsCountRepository()
    }

    public func pinnedConversationsCountRepo() -> any PinnedConversationsCountRepositoryProtocol {
        MockPinnedConversationsCountRepository()
    }

    public func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol {
        MockInviteRepository()
    }

    public func requestAgentJoin(slug: String, instructions: String, forceErrorCode: Int? = nil) async throws -> ConvosAPI.AgentJoinResponse {
        if let forceErrorCode {
            switch forceErrorCode {
            case 502: throw APIError.agentProvisionFailed
            case 503: throw APIError.noAgentsAvailable
            case 504: throw APIError.agentPoolTimeout
            default: throw APIError.serverError("Mock forced error \(forceErrorCode)")
            }
        }
        return .init(success: true, joined: true)
    }

    public func redeemInviteCode(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        .init(code: "MOCKCODE", name: nil, maxRedemptions: 5, redemptionCount: 0, remainingRedemptions: 5)
    }

    public func fetchInviteCodeStatus(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        .init(code: code.uppercased(), name: nil, maxRedemptions: 5, redemptionCount: 1, remainingRedemptions: 4)
    }

    public func conversationRepository(for conversationId: String, inboxId: String, clientId: String) async throws -> any ConversationRepositoryProtocol {
        MockConversationRepository()
    }

    public func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol {
        MockMessagesRepository(conversationId: conversationId)
    }

    public func photoPreferencesRepository(for conversationId: String) -> any PhotoPreferencesRepositoryProtocol {
        MockPhotoPreferencesRepository()
    }

    public func photoPreferencesWriter() -> any PhotoPreferencesWriterProtocol {
        MockPhotoPreferencesWriter()
    }

    public func voiceMemoTranscriptRepository() -> any VoiceMemoTranscriptRepositoryProtocol {
        MockVoiceMemoTranscriptRepository()
    }

    public func voiceMemoTranscriptWriter() -> any VoiceMemoTranscriptWriterProtocol {
        MockVoiceMemoTranscriptWriter()
    }

    public func voiceMemoTranscriptionService() -> any VoiceMemoTranscriptionServicing {
        MockVoiceMemoTranscriptionService()
    }

    public func attachmentLocalStateWriter() -> any AttachmentLocalStateWriterProtocol {
        MockAttachmentLocalStateWriter()
    }

    private static let mockDatabase: DatabaseQueue = MockDatabaseManager.shared.dbPool

    public func assistantFilesLinksRepository(for conversationId: String) -> AssistantFilesLinksRepository {
        AssistantFilesLinksRepository(dbReader: Self.mockDatabase, conversationId: conversationId)
    }

    // MARK: - Lifecycle Management

    public func setActiveClientId(_ clientId: String?) async {}

    public func wakeInboxForNotification(clientId: String, inboxId: String) async {}

    public func wakeInboxForNotification(conversationId: String) async {}

    public func isInboxAwake(clientId: String) async -> Bool {
        true
    }

    public func isInboxSleeping(clientId: String) async -> Bool {
        false
    }

    // MARK: - Debug

    public func pendingInviteDetails() throws -> [PendingInviteDetail] {
        []
    }

    public func deleteExpiredPendingInvites() async throws -> Int {
        0
    }

    public func orphanedInboxDetails() throws -> [OrphanedInboxDetail] {
        []
    }

    public func deleteOrphanedInbox(clientId: String, inboxId: String) async throws {}

    // MARK: - Asset Renewal

    public func makeAssetRenewalManager() async -> AssetRenewalManager {
        let dbManager = MockDatabaseManager.shared
        let recoveryHandler = ExpiredAssetRecoveryHandler(databaseWriter: dbManager.dbWriter)
        return AssetRenewalManager(
            databaseWriter: dbManager.dbWriter,
            apiClient: MockAPIClient(),
            recoveryHandler: recoveryHandler
        )
    }

    // MARK: - Connections

    public func connectionManager(
        oauthProvider: any OAuthSessionProvider,
        callbackURLScheme: String
    ) -> any ConnectionManagerProtocol {
        MockConnectionManager()
    }

    public func connectionRepository() -> any ConnectionRepositoryProtocol {
        MockConnectionRepository()
    }
}
