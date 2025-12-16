#if canImport(UIKit)
import Combine
import Foundation

public final class MockInboxesService: SessionManagerProtocol {
    private let mockMessagingService: MockMessagingService = MockMessagingService()

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
        MockMessagesRepository(conversation: .mock(id: conversationId))
    }
}

// Separate mock for ConversationsCountRepository
class MockConversationsCountRepository: ConversationsCountRepositoryProtocol {
    var conversationsCount: AnyPublisher<Int, Never> {
        Just(1).eraseToAnyPublisher()
    }

    func fetchCount() throws -> Int {
        1
    }
}

#endif
