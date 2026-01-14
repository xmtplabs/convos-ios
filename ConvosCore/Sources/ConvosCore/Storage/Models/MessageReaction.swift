import Foundation

// MARK: - MessageReaction

public struct MessageReaction: MessageType, Hashable, Codable, Sendable {
    public let id: String
    public let conversation: Conversation
    public let sender: ConversationMember
    public let source: MessageSource
    public let status: MessageStatus
    public let content: MessageContent
    public let date: Date

    public let emoji: String // same as content.text

    public var reactions: [MessageReaction] { [] }

    public init(
        id: String,
        conversation: Conversation,
        sender: ConversationMember,
        source: MessageSource,
        status: MessageStatus,
        content: MessageContent,
        date: Date,
        emoji: String
    ) {
        self.id = id
        self.conversation = conversation
        self.sender = sender
        self.source = source
        self.status = status
        self.content = content
        self.date = date
        self.emoji = emoji
    }
}

public extension MessageReaction {
    static func mock(
        emoji: String = "❤️",
        sender: ConversationMember? = nil
    ) -> MessageReaction {
        let mockSender = sender ?? .mock(isCurrentUser: false)
        return MessageReaction(
            id: "mock-reaction-\(UUID().uuidString)",
            conversation: .mock(),
            sender: mockSender,
            source: mockSender.isCurrentUser ? .outgoing : .incoming,
            status: .published,
            content: .emoji(emoji),
            date: Date(),
            emoji: emoji
        )
    }
}
