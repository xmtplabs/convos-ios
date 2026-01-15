import Foundation

// MARK: - AnyMessage

public enum AnyMessage: Hashable, Codable, Sendable, Identifiable {
    public var id: String { base.id }
    public enum Origin: Hashable, Codable, Sendable {
        case existing // message was loaded initially or was previously seen (inserted/paginated)
        case paginated // message was loaded via pagination for the first time
        case inserted // new message that arrived after initialization
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
}
