import ConvosCore
import DifferenceKit
import Foundation

enum MessagesListItemAlignment {
    case leading, center, trailing, fullWidth
}

enum MessageBubbleType {
    case normal, tailed, none
}

struct MessagesGroup: Identifiable, Equatable, Hashable {
    let id: String
    let sender: ConversationMember // The sender of all messages in this group
    let messages: [AnyMessage] // Contains only published messages
    let unpublished: [AnyMessage] // Contains unpublished messages (failed, unpublished, etc.)
    let isLastGroup: Bool
    let isLastGroupSentByCurrentUser: Bool

    /// All messages in this group (published + unpublished)
    var allMessages: [AnyMessage] {
        messages + unpublished
    }

    static func == (lhs: MessagesGroup, rhs: MessagesGroup) -> Bool {
        lhs.id == rhs.id &&
        lhs.sender == rhs.sender &&
        lhs.messages == rhs.messages &&
        lhs.unpublished == rhs.unpublished &&
        lhs.isLastGroup == rhs.isLastGroup &&
        lhs.isLastGroupSentByCurrentUser == rhs.isLastGroupSentByCurrentUser
    }
}

// MARK: - Mock Data
extension MessagesGroup {
    static var mockIncoming: MessagesGroup {
        let sender = ConversationMember.mock(isCurrentUser: false)
        let messages: [AnyMessage] = [
            .message(Message.mock(text: "Hey there!", sender: sender, status: .published), .existing),
            .message(Message.mock(text: "How are you doing today?", sender: sender, status: .published), .existing),
            .message(Message.mock(text: "Let me know when you're free", sender: sender, status: .published), .existing)
        ]
        return MessagesGroup(
            id: "mock-incoming-group",
            sender: sender,
            messages: messages,
            unpublished: [],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        )
    }

    static var mockOutgoing: MessagesGroup {
        let sender = ConversationMember.mock(isCurrentUser: true)
        let messages: [AnyMessage] = [
            .message(Message.mock(text: "I'm doing great!", sender: sender, status: .published), .existing),
            .message(Message.mock(text: "Thanks for asking 😊", sender: sender, status: .published), .existing)
        ]
        return MessagesGroup(
            id: "mock-outgoing-group",
            sender: sender,
            messages: messages,
            unpublished: [],
            isLastGroup: false,
            isLastGroupSentByCurrentUser: true
        )
    }

    static var mockMixed: MessagesGroup {
        let sender = ConversationMember.mock(isCurrentUser: true)
        let published: [AnyMessage] = [
            .message(Message.mock(text: "Here's my first message", sender: sender, status: .published), .existing),
            .message(Message.mock(text: "And another one", sender: sender, status: .published), .existing)
        ]
        let unpublished: [AnyMessage] = [
            .message(Message.mock(text: "This one is still sending...", sender: sender, status: .unpublished), .existing)
        ]
        return MessagesGroup(
            id: "mock-mixed-group",
            sender: sender,
            messages: published,
            unpublished: unpublished,
            isLastGroup: true,
            isLastGroupSentByCurrentUser: true
        )
    }
}

enum MessagesListItemType: Identifiable, Equatable, Hashable {
    /// Shows metadata changes, new members being added, etc
    /// Ex: "Louis joined by invitation"
    case update(id: String, update: ConversationUpdate, origin: AnyMessage.Origin)

    /// Shows a timestamp for when the next message in the list was sent
    /// Shown only if the time between messages was greater than an hour
    case date(DateGroup)

    /// Messages sent by the same sender
    case messages(MessagesGroup)

    /// Shows invite information at the top of the conversation (for creators)
    case invite(Invite)

    /// Shows conversation info at the top of the conversation (for non-creators)
    case conversationInfo(Conversation)

    var id: String {
        switch self {
        case .update(let id, _, _):
            return "update-\(id)"
        case .date(let dateGroup):
            return "date-\(dateGroup.differenceIdentifier)"
        case .messages(let group):
            return "messages-group-\(group.id)"
        case .invite(let invite):
            return "invite-\(invite.id)"
        case .conversationInfo(let conversation):
            return "conversation-info-\(conversation.id)"
        }
    }

    var isMessagesGroupSentByCurrentUser: Bool {
        switch self {
        case .messages(let group):
            return group.sender.isCurrentUser
        default:
            return false
        }
    }

    /// Returns the origin of this list item (if applicable)
    var origin: AnyMessage.Origin? {
        switch self {
        case .update(_, _, let origin):
            return origin
        case .messages(let group):
            return group.messages.last?.origin
        case .date, .invite, .conversationInfo:
            return nil
        }
    }

    /// Whether this item should animate when displayed
    var shouldAnimate: Bool {
        origin == .inserted
    }

    /// The alignment for this item when displayed in the collection view
    var alignment: MessagesListItemAlignment {
        switch self {
        case .invite, .conversationInfo:
            return .center
        default:
            return .fullWidth
        }
    }
}

// MARK: - Differentiable Conformance
extension MessagesListItemType: Differentiable {
    var differenceIdentifier: Int {
        id.hashValue
    }

    func isContentEqual(to source: MessagesListItemType) -> Bool {
        self == source
    }
}

// MARK: - Mock Data for MessagesListItemType
extension MessagesListItemType {
    static var mockDate: MessagesListItemType {
        .date(DateGroup(date: Date()))
    }

    static var mockUpdate: MessagesListItemType {
        .update(id: "mock-update", update: ConversationUpdate.mock(), origin: .existing)
    }

    static var mockIncomingMessages: MessagesListItemType {
        .messages(.mockIncoming)
    }

    static var mockOutgoingMessages: MessagesListItemType {
        .messages(.mockOutgoing)
    }

    static var mockMixedMessages: MessagesListItemType {
        .messages(.mockMixed)
    }

    static var mockConversation: [MessagesListItemType] {
        [
            .mockDate,
            .mockIncomingMessages,
            .mockOutgoingMessages,
            .mockUpdate,
            .mockMixedMessages
        ]
    }
}
