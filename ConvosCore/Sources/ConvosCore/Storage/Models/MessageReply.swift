import Foundation

// MARK: - MessageReply

public struct MessageReply: Hashable, Codable, Sendable {
    public let id: String
    public let sender: ConversationMember
    public let source: MessageSource
    public let status: MessageStatus
    public let content: MessageContent
    public let date: Date

    public let parentMessage: Message
    public let reactions: [MessageReaction]

    public init(
        id: String,
        sender: ConversationMember,
        source: MessageSource,
        status: MessageStatus,
        content: MessageContent,
        date: Date,
        parentMessage: Message,
        reactions: [MessageReaction]
    ) {
        self.id = id
        self.sender = sender
        self.source = source
        self.status = status
        self.content = content
        self.date = date
        self.parentMessage = parentMessage
        self.reactions = reactions
    }
}
