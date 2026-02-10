import Foundation

// MARK: - AnyMessage

public enum AnyMessage: Hashable, Equatable, Codable, Sendable, Identifiable {
    public var id: String { base.id }
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

    public var base: MessageType {
        switch self {
        case .message(let message, _):
            return message
        case .reply(let reply, _):
            return reply
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
