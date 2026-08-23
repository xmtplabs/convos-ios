import Foundation

// MARK: - Message

public struct Message: Hashable, Codable, Sendable {
    public let id: String
    /// The published XMTP message id. `id` remains the stable local/client id
    /// used by the transcript while optimistic sends are reconciled.
    public let xmtpId: String?
    public let sender: ConversationMember
    public let source: MessageSource
    public let status: MessageStatus
    public let content: MessageContent
    public let date: Date

    public let reactions: [MessageReaction]

    public init(
        id: String,
        xmtpId: String? = nil,
        sender: ConversationMember,
        source: MessageSource,
        status: MessageStatus,
        content: MessageContent,
        date: Date,
        reactions: [MessageReaction]
    ) {
        self.id = id
        self.xmtpId = xmtpId
        self.sender = sender
        self.source = source
        self.status = status
        self.content = content
        self.date = date
        self.reactions = reactions
    }
}
