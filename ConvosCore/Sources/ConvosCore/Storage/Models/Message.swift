import Foundation

// MARK: - Message

public struct Message: Hashable, Codable, Sendable {
    public let id: String
    public let sender: ConversationMember
    public let source: MessageSource
    public let status: MessageStatus
    public let content: MessageContent
    public let date: Date

    public let reactions: [MessageReaction]

    public init(
        id: String,
        sender: ConversationMember,
        source: MessageSource,
        status: MessageStatus,
        content: MessageContent,
        date: Date,
        reactions: [MessageReaction]
    ) {
        self.id = id
        self.sender = sender
        self.source = source
        self.status = status
        self.content = content
        self.date = date
        self.reactions = reactions
    }
}
