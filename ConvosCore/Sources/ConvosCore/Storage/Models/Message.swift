import Foundation

public struct MessageInvite: Sendable, Hashable, Codable {
    public let inviteSlug: String
    public let conversationName: String?
    public let conversationDescription: String?
    public let imageURL: URL?
    public let expiresAt: Date?
    public let conversationExpiresAt: Date?
}

public extension MessageInvite {
    /// Attempts to parse a `MessageInvite` from text content.
    /// Returns `nil` if the text is not a valid Convos invite URL.
    /// - Parameter text: The text to parse (will be trimmed of whitespace)
    /// - Returns: A `MessageInvite` if the text contains a valid invite URL, otherwise `nil`
    static func from(text: String) -> MessageInvite? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedText),
              let inviteCode = url.convosInviteCode,
              let signedInvite = try? SignedInvite.fromInviteCode(inviteCode) else {
            return nil
        }
        let imageURL: URL? = signedInvite.imageURL.flatMap { URL(string: $0) }
        return MessageInvite(
            inviteSlug: inviteCode,
            conversationName: signedInvite.name,
            conversationDescription: signedInvite.description_p,
            imageURL: imageURL,
            expiresAt: signedInvite.expiresAt,
            conversationExpiresAt: signedInvite.conversationExpiresAt
        )
    }

    static var empty: MessageInvite {
        .init(
            inviteSlug: "message-invite-slug",
            conversationName: nil,
            conversationDescription: nil,
            imageURL: nil,
            expiresAt: nil,
            conversationExpiresAt: nil
        )
    }
    static var mock: MessageInvite {
        .init(
            inviteSlug: "message-invite-slug",
            conversationName: "Untitled",
            conversationDescription: "A place to chat",
            imageURL: nil,
            expiresAt: nil,
            conversationExpiresAt: nil
        )
    }
}

public protocol MessageType: Sendable {
    var id: String { get }
    var conversation: Conversation { get }
    var sender: ConversationMember { get }
    var source: MessageSource { get }
    var status: MessageStatus { get }
    var content: MessageContent { get }
    var date: Date { get }
}

public enum AnyMessage: Hashable, Codable, Sendable {
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

public enum MessageContent: Hashable, Codable, Sendable {
    case text(String),
         invite(MessageInvite),
         emoji(String), // all emoji, not a reaction
         attachment(URL),
         attachments([URL]),
         update(ConversationUpdate)

    public var showsInMessagesList: Bool {
        switch self {
        case .update(let update):
            return update.showsInMessagesList
        default:
            return true
        }
    }

    public var isUpdate: Bool {
        switch self {
        case .update:
            true
        default:
            false
        }
    }

    public var isEmoji: Bool {
        switch self {
        case .emoji:
            true
        default:
            false
        }
    }

    public var showsSender: Bool {
        switch self {
        case .update:
            false
        default:
            true
        }
    }
}

public struct Message: MessageType, Hashable, Codable, Sendable {
    public let id: String
    public let conversation: Conversation
    public let sender: ConversationMember
    public let source: MessageSource
    public let status: MessageStatus
    public let content: MessageContent
    public let date: Date

    public let reactions: [MessageReaction]
}

public struct MessageReply: MessageType, Hashable, Codable, Sendable {
    public let id: String
    public let conversation: Conversation
    public let sender: ConversationMember
    public let source: MessageSource
    public let status: MessageStatus
    public let content: MessageContent
    public let date: Date

    public let parentMessage: Message
    public let reactions: [MessageReaction]
}

public struct MessageReaction: MessageType, Hashable, Codable, Sendable {
    public let id: String
    public let conversation: Conversation
    public let sender: ConversationMember
    public let source: MessageSource
    public let status: MessageStatus
    public let content: MessageContent
    public let date: Date

    public let emoji: String // same as content.text
}
