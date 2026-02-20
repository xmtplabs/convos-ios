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

    func addInbox() async -> (service: AnyMessagingService, conversationId: String?)
    func addInboxOnly() async -> AnyMessagingService
    func deleteInbox(clientId: String, inboxId: String) async throws
    func deleteAllInboxes() async throws
    func deleteAllInboxesWithProgress() -> AsyncThrowingStream<InboxDeletionProgress, Error>

    // MARK: Messaging Services

    func messagingService(for clientId: String, inboxId: String) async throws -> AnyMessagingService
    func messagingServiceSync(for clientId: String, inboxId: String) -> AnyMessagingService

    // MARK: Factory methods for repositories

    func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol

    func conversationRepository(
        for conversationId: String,
        inboxId: String,
        clientId: String
    ) async throws -> any ConversationRepositoryProtocol

    func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol

    func photoPreferencesRepository(for conversationId: String) -> any PhotoPreferencesRepositoryProtocol
    func photoPreferencesWriter() -> any PhotoPreferencesWriterProtocol

    func attachmentLocalStateWriter() -> any AttachmentLocalStateWriterProtocol

    func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol
    func conversationsCountRepo(
        for consent: [Consent],
        kinds: [ConversationKind]
    ) -> any ConversationsCountRepositoryProtocol
    func pinnedConversationsCountRepo() -> any PinnedConversationsCountRepositoryProtocol

    // MARK: Notifications

    func notifyChangesInDatabase()
    func shouldDisplayNotification(for conversationId: String) async -> Bool

    // MARK: - Lifecycle Management

    /// Sets the currently active client ID. This protects the inbox from being put to sleep during rebalancing.
    /// Pass nil when no conversation is active (e.g., user is on conversation list).
    func setActiveClientId(_ clientId: String?) async

    func wakeInboxForNotification(clientId: String, inboxId: String) async
    func wakeInboxForNotification(conversationId: String) async
    func isInboxAwake(clientId: String) async -> Bool
    func isInboxSleeping(clientId: String) async -> Bool

    // MARK: Helpers

    func inboxId(for conversationId: String) async -> String?

    // MARK: Debug

    func pendingInviteDetails() throws -> [PendingInviteDetail]
    func deleteExpiredPendingInvites() async throws -> Int
}
