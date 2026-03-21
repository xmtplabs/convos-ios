import Foundation

public enum MessagesListItemAlignment: Sendable {
    case leading, center, trailing, fullWidth
}

public enum MessageBubbleType: Sendable {
    case normal, tailed, none
}

public enum MessagesListItemType: Identifiable, Equatable, Hashable, Sendable {
    case update(id: String, update: ConversationUpdate, origin: AnyMessage.Origin)
    case date(DateGroup)
    case messages(MessagesGroup)
    case invite(Invite)
    case conversationInfo(Conversation)
    case agentOutOfCredits(Profile)
    case assistantJoinStatus(AssistantJoinStatus, requesterName: String?, date: Date)

    public var id: String {
        switch self {
        case .update(let id, _, _):
            return "update-\(id)"
        case .date(let dateGroup):
            return "date-\(dateGroup.hashValue)"
        case .messages(let group):
            return "messages-group-\(group.id)"
        case .invite(let invite):
            return "invite-\(invite.id)"
        case .conversationInfo(let conversation):
            return "conversation-info-\(conversation.id)"
        case .agentOutOfCredits(let profile):
            return "agent-out-of-credits-\(profile.inboxId)"
        case .assistantJoinStatus:
            return "assistant-join"
        }
    }

    public var isMessagesGroupSentByCurrentUser: Bool {
        switch self {
        case .messages(let group):
            return group.sender.isCurrentUser
        default:
            return false
        }
    }

    public var lastMessageInGroup: AnyMessage? {
        switch self {
        case .messages(let group):
            return group.messages.last
        default:
            return nil
        }
    }

    public var origin: AnyMessage.Origin? {
        switch self {
        case .update(_, _, let origin):
            return origin
        case .messages(let group):
            return group.messages.last?.origin
        case .date, .invite, .conversationInfo, .agentOutOfCredits, .assistantJoinStatus:
            return nil
        }
    }

    public var shouldAnimate: Bool {
        origin == .inserted
    }

    public var alignment: MessagesListItemAlignment {
        switch self {
        case .invite, .conversationInfo:
            return .center
        case .agentOutOfCredits:
            return .fullWidth
        default:
            return .fullWidth
        }
    }

    public var cellReuseIdentifier: String {
        switch self {
        case .date:
            return "MessagesListItemTypeCell-date"
        case .update:
            return "MessagesListItemTypeCell-update"
        case .messages:
            return "MessagesListItemTypeCell-messages"
        case .invite:
            return "MessagesListItemTypeCell-invite"
        case .conversationInfo:
            return "MessagesListItemTypeCell-conversationInfo"
        case .agentOutOfCredits:
            return "MessagesListItemTypeCell-agentOutOfCredits"
        case .assistantJoinStatus:
            return "MessagesListItemTypeCell-assistantJoinStatus"
        }
    }

    public static var allCellReuseIdentifiers: [String] {
        [
            "MessagesListItemTypeCell-date",
            "MessagesListItemTypeCell-update",
            "MessagesListItemTypeCell-messages",
            "MessagesListItemTypeCell-invite",
            "MessagesListItemTypeCell-conversationInfo",
            "MessagesListItemTypeCell-agentOutOfCredits",
            "MessagesListItemTypeCell-assistantJoinStatus",
        ]
    }

    public var lastMessageId: String? {
        switch self {
        case .messages(let group):
            return group.messages.last?.messageId
        default:
            return nil
        }
    }
}

extension Array where Element == MessagesListItemType {
    public var lastMessageId: String? {
        for item in reversed() {
            if let id = item.lastMessageId {
                return id
            }
        }
        return nil
    }
}
