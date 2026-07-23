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
    public let mimeType: String?
    public let senderDisplayName: String?
    public let isOutgoing: Bool
    public let status: VoiceMemoTranscriptStatus
    public let text: String?
    public let errorDescription: String?

    public init(
        parentMessageId: String,
        conversationId: String,
        attachmentKey: String,
        mimeType: String? = nil,
        senderDisplayName: String? = nil,
        isOutgoing: Bool,
        status: VoiceMemoTranscriptStatus,
        text: String?,
        errorDescription: String? = nil
    ) {
        self.parentMessageId = parentMessageId
        self.conversationId = conversationId
        self.attachmentKey = attachmentKey
        self.mimeType = mimeType
        self.senderDisplayName = senderDisplayName
        self.isOutgoing = isOutgoing
        self.status = status
        self.text = text
        self.errorDescription = errorDescription
    }
}

public enum MessagesListItemType: Identifiable, Equatable, Hashable, Sendable {
    case update(id: String, update: ConversationUpdate, origin: AnyMessage.Origin)
    case date(DateGroup)
    case messages(MessagesGroup)
    case invite(Invite)
    case conversationInfo(Conversation)
    case agentOutOfCredits(ConversationMember, isCurrentUserCreator: Bool)
    case agentJoinStatus(AgentJoinStatus, requesterName: String?, date: Date)
    case agentPresentInfo(agent: ConversationMember, inviterName: String?)
    case connectionEvent(id: String, summary: ConnectionEventSummary, origin: AnyMessage.Origin)
    case capabilityConnect(id: String, prompt: CapabilityConnectPrompt, agentName: String, origin: AnyMessage.Origin)
    case agentBuilderSummary(AgentBuilderCardContent)
    case agentActivating(AgentActivatingCardContent)
    /// The agent-DM disclosure header: always the first cell of an agent-DM
    /// transcript (and its empty state). See docs/plans/agent-dms.md.
    case agentDmInfo(agentName: String)
    case typingIndicator(typers: [ConversationMember])

    public var id: String {
        switch self {
        case .update(let id, _, _):
            return "update-\(id)"
        case .date(let dateGroup):
            return "date-\(dateGroup.hashValue)"
        case .messages(let group):
            return "messages-group-\(group.id)"
        case .invite:
            // The transcript hosts at most one invite card (index 0), so its
            // identity is the slot, not the invite payload. Keying on the
            // payload made every invite change (hydration, the embedded
            // new-convo flow's created->claimed swap) an animated
            // delete+insert that cross-faded two full cards and restarted
            // the Scan tab camera; a stable id turns those into in-place
            // reconfigurations of the single card.
            return "invite"
        case .conversationInfo(let conversation):
            return "conversation-info-\(conversation.id)"
        case .agentOutOfCredits(let member, _):
            return "agent-out-of-credits-\(member.profile.inboxId)"
        case .agentJoinStatus:
            return "agent-join"
        case .agentPresentInfo:
            return "agent-present-info"
        case .connectionEvent(let id, _, _):
            return "connection-event-\(id)"
        case .capabilityConnect(let id, _, _, _):
            return "capability-connect-\(id)"
        case .agentBuilderSummary(let content):
            return "agent-builder-summary-\(content.id)"
        case .agentActivating(let content):
            return "agent-activating-\(content.id)"
        case .agentDmInfo:
            return "agent-dm-info"
        case .typingIndicator:
            return "typing-indicator"
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

    public var isFullBleedAttachmentGroup: Bool {
        switch self {
        case .messages(let group):
            return group.isFullBleedAttachment
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
        case .date, .invite, .conversationInfo, .agentOutOfCredits, .agentJoinStatus, .agentPresentInfo, .agentBuilderSummary, .agentActivating, .agentDmInfo, .typingIndicator:
            return nil
        case .connectionEvent(_, _, let origin):
            return origin
        case .capabilityConnect(_, _, _, let origin):
            return origin
        }
    }

    public var shouldAnimate: Bool {
        origin == .inserted
    }

    public var alignment: MessagesListItemAlignment {
        switch self {
        case .invite, .conversationInfo, .agentBuilderSummary, .agentActivating:
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
        case .agentJoinStatus:
            return "MessagesListItemTypeCell-agentJoinStatus"
        case .agentPresentInfo:
            return "MessagesListItemTypeCell-agentPresentInfo"
        case .connectionEvent:
            return "MessagesListItemTypeCell-connectionEvent"
        case .capabilityConnect:
            return "MessagesListItemTypeCell-capabilityConnect"
        case .agentBuilderSummary:
            return "MessagesListItemTypeCell-agentBuilderSummary"
        case .agentActivating:
            return "MessagesListItemTypeCell-agentActivating"
        case .agentDmInfo:
            return "MessagesListItemTypeCell-agentDmInfo"
        case .typingIndicator:
            return "TypingIndicatorCollectionCell"
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
            "MessagesListItemTypeCell-agentJoinStatus",
            "MessagesListItemTypeCell-agentPresentInfo",
            "MessagesListItemTypeCell-connectionEvent",
            "MessagesListItemTypeCell-capabilityConnect",
            "MessagesListItemTypeCell-agentBuilderSummary",
            "MessagesListItemTypeCell-agentActivating",
            "MessagesListItemTypeCell-agentDmInfo",
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
    public var countMessages: Int {
        reduce(0) { count, item in
            if case .messages(let group) = item {
                return count + group.messages.count
            }
            return count
        }
    }

    public var lastMessageId: String? {
        for item in reversed() {
            if let id = item.lastMessageId {
                return id
            }
        }
        return nil
    }
}
