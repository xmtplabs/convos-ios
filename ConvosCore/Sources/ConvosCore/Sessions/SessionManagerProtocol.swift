import Combine
import Foundation

public protocol SessionManagerProtocol: AnyObject {
    // MARK: Inbox Management

    func addInbox() async -> AnyMessagingService
    func deleteInbox(clientId: String) async throws
    func deleteAllInboxes() async throws

    // MARK: Messaging Services

    func messagingService(for clientId: String, inboxId: String) -> AnyMessagingService

    // MARK: Factory methods for repositories

    func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol

    func conversationRepository(
        for conversationId: String,
        inboxId: String,
        clientId: String
    ) -> any ConversationRepositoryProtocol

    func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol

    func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol
    func conversationsCountRepo(
        for consent: [Consent],
        kinds: [ConversationKind]
    ) -> any ConversationsCountRepositoryProtocol

    // MARK: Notifications

    func notifyChangesInDatabase()
    func shouldDisplayNotification(for conversationId: String) async -> Bool

    // MARK: Helpers

    func inboxId(for conversationId: String) async -> String?
}
