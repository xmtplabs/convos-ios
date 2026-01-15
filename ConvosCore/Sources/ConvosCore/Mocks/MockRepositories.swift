import Combine
import Foundation

// MARK: - Mock Conversations Repository

/// Mock implementation of ConversationsRepositoryProtocol for testing
public final class MockConversationsRepository: ConversationsRepositoryProtocol, @unchecked Sendable {
    public var mockConversations: [Conversation]

    public init(conversations: [Conversation] = [.mock(), .mock(), .mock()]) {
        self.mockConversations = conversations
    }

    public var conversationsPublisher: AnyPublisher<[Conversation], Never> {
        Just(mockConversations).eraseToAnyPublisher()
    }

    public func fetchAll() throws -> [Conversation] {
        mockConversations
    }
}

// MARK: - Mock Conversations Count Repository

/// Mock implementation of ConversationsCountRepositoryProtocol for testing
public final class MockConversationsCountRepository: ConversationsCountRepositoryProtocol, @unchecked Sendable {
    public var mockCount: Int

    public init(count: Int = 1) {
        self.mockCount = count
    }

    public var conversationsCount: AnyPublisher<Int, Never> {
        Just(mockCount).eraseToAnyPublisher()
    }

    public func fetchCount() throws -> Int {
        mockCount
    }
}

// MARK: - Mock Pinned Conversations Count Repository

public final class MockPinnedConversationsCountRepository: PinnedConversationsCountRepositoryProtocol, @unchecked Sendable {
    public var mockCount: Int

    public init(count: Int = 0) {
        self.mockCount = count
    }

    public var pinnedCount: AnyPublisher<Int, Never> {
        Just(mockCount).eraseToAnyPublisher()
    }

    public func fetchCount() throws -> Int {
        mockCount
    }
}

// MARK: - Mock Conversation Repository

/// Mock implementation of ConversationRepositoryProtocol for testing
public final class MockConversationRepository: ConversationRepositoryProtocol, @unchecked Sendable {
    public var mockConversation: Conversation?

    public init(conversation: Conversation? = .mock()) {
        self.mockConversation = conversation
    }

    public var conversationId: String {
        mockConversation?.id ?? ""
    }

    public var myProfileRepository: any MyProfileRepositoryProtocol {
        MockMyProfileRepository()
    }

    public var conversationPublisher: AnyPublisher<Conversation?, Never> {
        Just(mockConversation).eraseToAnyPublisher()
    }

    public func fetchConversation() throws -> Conversation? {
        mockConversation
    }
}

// MARK: - Mock My Profile Repository

/// Mock implementation of MyProfileRepositoryProtocol for testing
public final class MockMyProfileRepository: MyProfileRepositoryProtocol, @unchecked Sendable {
    public var mockProfile: Profile

    public init(profile: Profile = .empty(inboxId: "mock-inbox-id")) {
        self.mockProfile = profile
    }

    public var myProfilePublisher: AnyPublisher<Profile, Never> {
        Just(mockProfile).eraseToAnyPublisher()
    }

    public func fetch() throws -> Profile {
        mockProfile
    }

    public func suspendObservation() {}

    public func resumeObservation() {}
}

// MARK: - Mock Messages Repository

/// Mock implementation of MessagesRepositoryProtocol for testing
public final class MockMessagesRepository: MessagesRepositoryProtocol, @unchecked Sendable {
    public var mockMessages: [AnyMessage]
    public var conversationId: String
    public private(set) var hasMoreMessages: Bool = false

    public init(conversationId: String = "mock-conversation-id", messages: [AnyMessage] = []) {
        self.conversationId = conversationId
        self.mockMessages = messages
    }

    public var messagesPublisher: AnyPublisher<[AnyMessage], Never> {
        Just(mockMessages).eraseToAnyPublisher()
    }

    public func fetchInitial() throws -> [AnyMessage] {
        let pageSize = 25
        let result = Array(mockMessages.suffix(pageSize))
        hasMoreMessages = mockMessages.count > pageSize
        return result
    }

    public func fetchPrevious() throws {
        hasMoreMessages = false
    }

    public var conversationMessagesPublisher: AnyPublisher<ConversationMessages, Never> {
        Just((conversationId, mockMessages)).eraseToAnyPublisher()
    }
}

// MARK: - Mock Draft Conversation Repository

/// Mock implementation of DraftConversationRepositoryProtocol for testing
public final class MockDraftConversationRepository: DraftConversationRepositoryProtocol, @unchecked Sendable {
    public var mockConversation: Conversation

    public init(conversation: Conversation = .mock(id: "draft-123")) {
        self.mockConversation = conversation
    }

    public var conversationId: String {
        mockConversation.id
    }

    public var messagesRepository: any MessagesRepositoryProtocol {
        MockMessagesRepository(conversationId: mockConversation.id)
    }

    public var myProfileRepository: any MyProfileRepositoryProtocol {
        MockMyProfileRepository()
    }

    public var conversationPublisher: AnyPublisher<Conversation?, Never> {
        Just(mockConversation).eraseToAnyPublisher()
    }

    public func fetchConversation() throws -> Conversation? {
        mockConversation
    }
}
