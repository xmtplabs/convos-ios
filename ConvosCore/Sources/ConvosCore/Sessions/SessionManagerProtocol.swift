import Combine
import Foundation

/// Progress events for inbox deletion
public enum InboxDeletionProgress: Sendable, Equatable {
    case clearingDeviceRegistration
    case stoppingServices(completed: Int, total: Int)
    case deletingFromDatabase
    case completed
}

public protocol SessionManagerProtocol: AnyObject, Sendable {
    // MARK: Inbox Management

    func addInbox() async throws -> (service: AnyMessagingService, conversationId: String?)
    func deleteAllInboxes() async throws
    func deleteAllInboxesWithProgress() -> AsyncThrowingStream<InboxDeletionProgress, Error>

    // MARK: Messaging Services

    func messagingService() async throws -> AnyMessagingService
    func messagingServiceSync() -> AnyMessagingService

    // MARK: Factory methods for repositories

    func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol
    func requestAgentJoin(slug: String, instructions: String, forceErrorCode: Int?) async throws -> ConvosAPI.AgentJoinResponse
    func redeemInviteCode(_ code: String) async throws -> ConvosAPI.InviteCodeStatus
    func fetchInviteCodeStatus(_ code: String) async throws -> ConvosAPI.InviteCodeStatus

    func conversationRepository(for conversationId: String) async throws -> any ConversationRepositoryProtocol

    func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol

    func photoPreferencesRepository(for conversationId: String) -> any PhotoPreferencesRepositoryProtocol
    func photoPreferencesWriter() -> any PhotoPreferencesWriterProtocol
    func voiceMemoTranscriptRepository() -> any VoiceMemoTranscriptRepositoryProtocol
    func voiceMemoTranscriptWriter() -> any VoiceMemoTranscriptWriterProtocol
    func voiceMemoTranscriptionService() -> any VoiceMemoTranscriptionServicing

    func attachmentLocalStateWriter() -> any AttachmentLocalStateWriterProtocol
    func assistantFilesLinksRepository(for conversationId: String) -> AssistantFilesLinksRepository

    func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol
    func conversationsCountRepo(
        for consent: [Consent],
        kinds: [ConversationKind]
    ) -> any ConversationsCountRepositoryProtocol
    func pinnedConversationsCountRepo() -> any PinnedConversationsCountRepositoryProtocol

    // MARK: Notifications

    func notifyChangesInDatabase()
    func shouldDisplayNotification(for conversationId: String) async -> Bool

    /// Ensures the messaging service is ready before processing a notification
    /// for the given conversation. Safe to call from the NSE.
    func wakeInboxForNotification(conversationId: String) async

    // MARK: Helpers

    func inboxId(for conversationId: String) async -> String?

    // MARK: Debug

    func pendingInviteDetails() throws -> [PendingInviteDetail]
    func deleteExpiredPendingInvites() async throws -> Int
    func isAccountOrphaned() throws -> Bool

    // MARK: Asset Renewal

    func makeAssetRenewalManager() async -> AssetRenewalManager
}

extension SessionManagerProtocol {
    public func requestAgentJoin(slug: String, instructions: String) async throws -> ConvosAPI.AgentJoinResponse {
        try await requestAgentJoin(slug: slug, instructions: instructions, forceErrorCode: nil)
    }
}
