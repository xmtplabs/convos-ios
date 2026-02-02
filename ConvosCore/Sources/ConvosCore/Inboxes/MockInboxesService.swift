import Combine
import Foundation

public final class MockInboxesService: @unchecked Sendable, SessionManagerProtocol {
    private let mockMessagingService: MockMessagingService
    private let conversationsRepositoryProvider: ConversationsRepositoryProtocol
    private let conversationsCountRepositoryProvider: ConversationsCountRepositoryProtocol
    private let pinnedConversationsCountRepositoryProvider: PinnedConversationsCountRepositoryProtocol
    private let messagingServiceHandler: ((String, String) async throws -> AnyMessagingService)?

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

    public init(
        conversationsRepository: ConversationsRepositoryProtocol = MockConversationsRepository(),
        conversationsCountRepository: ConversationsCountRepositoryProtocol = MockConversationsCountRepository(),
        pinnedConversationsCountRepository: PinnedConversationsCountRepositoryProtocol = MockPinnedConversationsCountRepository(),
        messagingServiceHandler: ((String, String) async throws -> AnyMessagingService)? = nil,
        mockMessagingService: MockMessagingService = MockMessagingService()
    ) {
        self.conversationsRepositoryProvider = conversationsRepository
        self.conversationsCountRepositoryProvider = conversationsCountRepository
        self.pinnedConversationsCountRepositoryProvider = pinnedConversationsCountRepository
        self.messagingServiceHandler = messagingServiceHandler
        self.mockMessagingService = mockMessagingService
    }

    // MARK: - Inbox Management

    public func addInbox() async -> AnyMessagingService {
        mockMessagingService
    }

    public func deleteInbox(clientId: String, inboxId: String) async throws {
    }

    public func deleteAllInboxes() async throws {
    }

    // MARK: - Messaging Services

    public func messagingService(for clientId: String, inboxId: String) async throws -> AnyMessagingService {
        if let messagingServiceHandler {
            return try await messagingServiceHandler(clientId, inboxId)
        }

        return mockMessagingService
    }

    // MARK: - Factory methods for repositories

    public func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol {
        conversationsRepositoryProvider
    }

    public func conversationsCountRepo(for consent: [Consent], kinds: [ConversationKind]) -> any ConversationsCountRepositoryProtocol {
        conversationsCountRepositoryProvider
    }

    public func pinnedConversationsCountRepo() -> any PinnedConversationsCountRepositoryProtocol {
        pinnedConversationsCountRepositoryProvider
    }

    public func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol {
        MockInviteRepository()
    }

    public func conversationRepository(for conversationId: String, inboxId: String, clientId: String) async throws -> any ConversationRepositoryProtocol {
        MockConversationRepository()
    }

    public func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol {
        MockMessagesRepository(conversationId: conversationId)
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
}
