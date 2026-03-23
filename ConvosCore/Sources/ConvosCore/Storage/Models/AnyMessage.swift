import Foundation

// MARK: - AnyMessage

public enum AnyMessage: Hashable, Equatable, Codable, Sendable, Identifiable {
    public var id: String { messageId }
    public enum Origin: Hashable, Codable, Sendable {
        case existing
        case paginated
        case inserted
    }

    case message(Message, Origin),
         reply(MessageReply, Origin)

    public var origin: Origin {
        switch self {
        case .message(_, let origin),
                .reply(_, let origin):
            return origin
        }
    }

    // Direct property accessors — each switch returns the concrete struct field directly.

    public var content: MessageContent {
        switch self {
        case .message(let message, _):
            return message.content
        case .reply(let reply, _):
            return reply.content
        }
    }

    public var sender: ConversationMember {
        switch self {
        case .message(let message, _):
            return message.sender
        case .reply(let reply, _):
            return reply.sender
        }
    }

    public var senderId: String {
        switch self {
        case .message(let message, _):
            return message.sender.profile.inboxId
        case .reply(let reply, _):
            return reply.sender.profile.inboxId
        }
    }

    public var senderIsCurrentUser: Bool {
        switch self {
        case .message(let message, _):
            return message.sender.isCurrentUser
        case .reply(let reply, _):
            return reply.sender.isCurrentUser
        }
    }

    public var messageId: String {
        switch self {
        case .message(let message, _):
            return message.id
        case .reply(let reply, _):
            return reply.id
        }
    }

    public var date: Date {
        switch self {
        case .message(let message, _):
            return message.date
        case .reply(let reply, _):
            return reply.date
        }
    }

    public var status: MessageStatus {
        switch self {
        case .message(let message, _):
            return message.status
        case .reply(let reply, _):
            return reply.status
        }
    }

    public var source: MessageSource {
        switch self {
        case .message(let message, _):
            return message.source
        case .reply(let reply, _):
            return reply.source
        }
    }

    public var reactions: [MessageReaction] {
        switch self {
        case .message(let message, _):
            return message.reactions
        case .reply(let reply, _):
            return reply.reactions
        }
    }

    public static func == (lhs: AnyMessage, rhs: AnyMessage) -> Bool {
        switch (lhs, rhs) {
        case let (.message(lMsg, _), .message(rMsg, _)):
            return lMsg == rMsg
        case let (.reply(lReply, _), .reply(rReply, _)):
            return lReply == rReply
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .message(let msg, _):
            hasher.combine(0)
            hasher.combine(msg)
        case .reply(let reply, _):
            hasher.combine(1)
            hasher.combine(reply)
        }
    }
}
