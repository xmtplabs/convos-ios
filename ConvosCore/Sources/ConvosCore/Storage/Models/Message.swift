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

    /// Set when this message is a reply to a widget (window.convos.replyToWidget).
    /// The transcript renders a reference card for the widget above the message,
    /// mirroring how a `MessageReply` renders its parent. Nil for ordinary
    /// messages. See ContextReplyCodec.
    public let widgetContext: ContextReplyContext?

    public init(
        id: String,
        sender: ConversationMember,
        source: MessageSource,
        status: MessageStatus,
        content: MessageContent,
        date: Date,
        reactions: [MessageReaction],
        widgetContext: ContextReplyContext? = nil
    ) {
        self.id = id
        self.sender = sender
        self.source = source
        self.status = status
        self.content = content
        self.date = date
        self.reactions = reactions
        self.widgetContext = widgetContext
    }
}
