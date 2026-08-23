import Foundation

// MARK: - MessageReply

public struct MessageReply: Hashable, Codable, Sendable {
    public let id: String
    /// The published XMTP message id. `id` is the stable local/client id.
    public let xmtpId: String?
    public let sender: ConversationMember
    public let source: MessageSource
    public let status: MessageStatus
    public let content: MessageContent
    public let date: Date

    public let parentMessage: Message
    public let reactions: [MessageReaction]

    public init(
        id: String,
        xmtpId: String? = nil,
        sender: ConversationMember,
        source: MessageSource,
        status: MessageStatus,
        content: MessageContent,
        date: Date,
        parentMessage: Message,
        reactions: [MessageReaction]
    ) {
        self.id = id
        self.xmtpId = xmtpId
        self.sender = sender
        self.source = source
        self.status = status
        self.content = content
        self.date = date
        self.parentMessage = parentMessage
        self.reactions = reactions
    }
}
