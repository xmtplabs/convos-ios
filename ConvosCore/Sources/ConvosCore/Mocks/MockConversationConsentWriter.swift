import Foundation

/// Mock implementation of ConversationConsentWriterProtocol for testing
public final class MockConversationConsentWriter: ConversationConsentWriterProtocol, @unchecked Sendable {
    public var joinedConversations: [Conversation] = []
    public var deletedConversations: [Conversation] = []
    public var deleteAllCalled: Bool = false

    public init() {}

    public func join(conversation: Conversation) async throws {
        joinedConversations.append(conversation)
    }

    public func delete(conversation: Conversation) async throws {
        deletedConversations.append(conversation)
    }

    public func deleteAll() async throws {
        deleteAllCalled = true
    }
}
