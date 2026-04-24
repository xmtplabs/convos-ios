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

    /// Returns the shared messaging service and an optional conversation id
    /// for a group pre-prepared by `UnusedConversationCache`. A background
    /// prewarm is kicked off for the next caller. `conversationId` is nil
    /// if no prepared group was available and the caller should create one
    /// on demand.
    func prepareNewConversation() async -> (service: AnyMessagingService, conversationId: String?)
    func deleteAllInboxes() async throws
    func deleteAllInboxesWithProgress() -> AsyncThrowingStream<InboxDeletionProgress, Error>

    // MARK: Messaging Services

    func messagingService() -> AnyMessagingService
    func messagingServiceSync() -> AnyMessagingService

    // MARK: Factory methods for repositories

    func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol
    func requestAgentJoin(slug: String, instructions: String, forceErrorCode: Int?) async throws -> ConvosAPI.AgentJoinResponse
    func redeemInviteCode(_ code: String) async throws -> ConvosAPI.InviteCodeStatus
    func fetchInviteCodeStatus(_ code: String) async throws -> ConvosAPI.InviteCodeStatus

    func conversationRepository(for conversationId: String) -> any ConversationRepositoryProtocol

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

    /// Tells the session manager whether the conversations list is currently
    /// on-screen. Used to suppress in-app notification banners — the list
    /// already surfaces the new-message indicator, so a banner would be
    /// redundant.
    func setIsOnConversationsList(_ isOn: Bool)

    /// Ensures the messaging service is ready before processing a notification
    /// for the given conversation. Safe to call from the NSE.
    func wakeInboxForNotification(conversationId: String)

    // MARK: Helpers

    func inboxId(for conversationId: String) async -> String?

    // MARK: Debug

    func pendingInviteDetails() throws -> [PendingInviteDetail]
    func deleteExpiredPendingInvites() async throws -> Int
    func isAccountOrphaned() throws -> Bool

    // MARK: Asset Renewal

    func makeAssetRenewalManager() async -> AssetRenewalManager

    // MARK: Connections

    func connectionManager(oauthProvider: any OAuthSessionProvider, callbackURLScheme: String) -> any ConnectionManagerProtocol
    func connectionRepository() -> any ConnectionRepositoryProtocol
}

extension SessionManagerProtocol {
    public func requestAgentJoin(slug: String, instructions: String) async throws -> ConvosAPI.AgentJoinResponse {
        try await requestAgentJoin(slug: slug, instructions: instructions, forceErrorCode: nil)
    }
}
