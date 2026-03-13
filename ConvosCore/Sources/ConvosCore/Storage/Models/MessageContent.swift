import Foundation

// MARK: - MessageContent

public enum MessageContent: Hashable, Codable, Sendable {
    case text(String),
         invite(MessageInvite),
         emoji(String), // all emoji, not a reaction
         attachment(HydratedAttachment),
         attachments([HydratedAttachment]),
         update(ConversationUpdate),
         assistantJoinRequest(status: AssistantJoinStatus, requestedByInboxId: String)

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
        case .update, .assistantJoinRequest:
            false
        default:
            true
        }
    }

    public var isAssistantJoinRequest: Bool {
        switch self {
        case .assistantJoinRequest:
            true
        default:
            false
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
