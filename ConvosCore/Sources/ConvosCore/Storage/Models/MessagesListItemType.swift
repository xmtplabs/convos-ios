import Foundation

public enum MessagesListItemAlignment: Sendable {
    case leading, center, trailing, fullWidth
}

public enum MessageBubbleType: Sendable {
    case normal, tailed, none
}

public struct VoiceMemoTranscriptListItem: Hashable, Equatable, Sendable {
    public let parentMessageId: String
    public let conversationId: String
    public let attachmentKey: String
    public let isOutgoing: Bool
    public let status: VoiceMemoTranscriptStatus
    public let text: String?
    public let isExpanded: Bool

    public init(
        parentMessageId: String,
        conversationId: String,
        attachmentKey: String,
        isOutgoing: Bool,
        status: VoiceMemoTranscriptStatus,
        text: String?,
        isExpanded: Bool
    ) {
        self.parentMessageId = parentMessageId
        self.conversationId = conversationId
        self.attachmentKey = attachmentKey
        self.isOutgoing = isOutgoing
        self.status = status
        self.text = text
        self.isExpanded = isExpanded
    }
}

public enum MessagesListItemType: Identifiable, Equatable, Hashable, Sendable {
    case update(id: String, update: ConversationUpdate, origin: AnyMessage.Origin)
    case date(DateGroup)
    case messages(MessagesGroup)
    case invite(Invite)
    case conversationInfo(Conversation)
    case agentOutOfCredits(Profile)
    case assistantJoinStatus(AssistantJoinStatus, requesterName: String?, date: Date)
    case assistantPresentInfo(agent: ConversationMember, inviterName: String?)
    case typingIndicator(typers: [ConversationMember])
    case voiceMemoTranscript(VoiceMemoTranscriptListItem)

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
        case .assistantPresentInfo:
            return "assistant-present-info"
        case .typingIndicator:
            return "typing-indicator"
        case .voiceMemoTranscript(let item):
            return "voice-memo-transcript-\(item.parentMessageId)"
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
        case .date, .invite, .conversationInfo, .agentOutOfCredits, .assistantJoinStatus, .assistantPresentInfo, .typingIndicator, .voiceMemoTranscript:
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
        case .voiceMemoTranscript(let item):
            return item.isOutgoing ? .trailing : .leading
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
        case .assistantPresentInfo:
            return "MessagesListItemTypeCell-assistantPresentInfo"
        case .typingIndicator:
            return "TypingIndicatorCollectionCell"
        case .voiceMemoTranscript:
            return "MessagesListItemTypeCell-voiceMemoTranscript"
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
            "MessagesListItemTypeCell-assistantPresentInfo",
            "MessagesListItemTypeCell-voiceMemoTranscript",
            "TypingIndicatorCollectionCell",
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
