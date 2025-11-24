import Combine
import Foundation

class MockMessagesRepository: MessagesRepositoryProtocol {
    let conversation: Conversation
    private var mockMessages: [AnyMessage] = []

    private(set) var hasMoreMessages: Bool = false

    init(conversation: Conversation) {
        self.conversation = conversation
    }

    func fetchInitial() throws -> [AnyMessage] {
        // Return the last 25 messages (or all if less than 25) to match default page size
        let pageSize = 25
        let result = Array(mockMessages.suffix(pageSize))
        hasMoreMessages = mockMessages.count > pageSize
        return result
    }

    func fetchPrevious() throws {
        // For mock, just set hasMoreMessages to false
        // Results are delivered through the publisher
        hasMoreMessages = false
    }

    var conversationMessagesPublisher: AnyPublisher<ConversationMessages, Never> {
        Just((conversation.id, mockMessages)).eraseToAnyPublisher()
    }
}
