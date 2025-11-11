import Combine
import Foundation

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

    public func addInbox() async -> AnyMessagingService {
        mockMessagingService
    }

    public func deleteInbox(clientId: String) async throws {
    }

    public func deleteInbox(for messagingService: AnyMessagingService) async throws {
    }

    public func deleteAllInboxes() async throws {
    }

    // MARK: - Messaging Services

    public func messagingService(for clientId: String, inboxId: String) -> AnyMessagingService {
        mockMessagingService
    }

    // MARK: - Factory methods for repositories

    public func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol {
        MockConversationsRepository()
    }

    public func conversationsCountRepo(for consent: [Consent], kinds: [ConversationKind]) -> any ConversationsCountRepositoryProtocol {
        MockConversationsCountRepository()
    }

    public func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol {
        MockInviteRepository()
    }

    public func conversationRepository(for conversationId: String, inboxId: String, clientId: String) -> any ConversationRepositoryProtocol {
        MockConversationRepository()
    }

    public func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol {
        MockMessagesRepository(conversationId: conversationId)
    }
}
