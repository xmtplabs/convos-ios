import Combine
import Foundation

public class MockMyProfileRepository: MyProfileRepositoryProtocol {
    public init() {}

    public var myProfilePublisher: AnyPublisher<Profile, Never> {
        Just(.empty(inboxId: "mock-inbox-id")).eraseToAnyPublisher()
    }

    public func fetch() throws -> Profile {
        .empty(inboxId: "mock-inbox-id")
    }

    public func suspendObservation() {}

    public func resumeObservation() {}
}

public class MockConversationRepository: ConversationRepositoryProtocol {
    public init() {}

    public var conversationPublisher: AnyPublisher<Conversation?, Never> {
        Just(conversation).eraseToAnyPublisher()
    }

    public var conversationId: String {
        conversation.id
    }

    public var myProfileRepository: any MyProfileRepositoryProtocol {
        MockMyProfileRepository()
    }

    private let conversation: Conversation = .mock()

    public func fetchConversation() throws -> Conversation? {
        conversation
    }
}

class MockDraftConversationRepository: DraftConversationRepositoryProtocol {
    var conversationId: String {
        conversation.id
    }

    var messagesRepository: any MessagesRepositoryProtocol {
        MockMessagesRepository(conversation: conversation)
    }

    var myProfileRepository: any MyProfileRepositoryProtocol {
        MockMyProfileRepository()
    }

    var conversationPublisher: AnyPublisher<Conversation?, Never> {
        Just(conversation).eraseToAnyPublisher()
    }

    private let conversation: Conversation = .mock(id: "draft-123")

    func fetchConversation() throws -> Conversation? {
        conversation
    }
}
