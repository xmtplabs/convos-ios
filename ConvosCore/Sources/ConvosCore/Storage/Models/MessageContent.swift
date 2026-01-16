import Foundation

// MARK: - MessageContent

public enum MessageContent: Hashable, Codable, Sendable {
    case text(String),
         invite(MessageInvite),
         emoji(String), // all emoji, not a reaction
         attachment(String),
         attachments([String]),
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

    public var isAttachment: Bool {
        switch self {
        case .attachment, .attachments:
            true
        default:
            false
        }
    }
}
