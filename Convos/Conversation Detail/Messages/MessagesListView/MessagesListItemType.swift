import ConvosCore
import DifferenceKit
import Foundation

// Core types (MessagesGroup, MessagesListItemType, DateGroup) have been moved to ConvosCore.
// This file contains DifferenceKit conformances and mock data that stay in the app target.

// MARK: - Differentiable Conformance
extension MessagesListItemType: Differentiable {
    public var differenceIdentifier: Int {
        id.hashValue
    }

    public func isContentEqual(to source: MessagesListItemType) -> Bool {
        self == source
    }
}

// MARK: - Mock Data for MessagesGroup
extension MessagesGroup {
    static var mockIncoming: MessagesGroup {
        let sender = ConversationMember.mock(isCurrentUser: false)
        let messages: [AnyMessage] = [
            .message(Message.mock(text: "Hey there!", sender: sender, status: .published), .existing),
            .message(Message.mock(text: "How are you doing today?", sender: sender, status: .published), .existing),
            .message(Message.mock(text: "Let me know when you're free", sender: sender, status: .published), .existing),
        ]
        return MessagesGroup(
            id: "mock-incoming-group",
            sender: sender,
            messages: messages,
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        )
    }

    static var mockOutgoing: MessagesGroup {
        let sender = ConversationMember.mock(isCurrentUser: true)
        let messages: [AnyMessage] = [
            .message(Message.mock(text: "I'm doing great!", sender: sender, status: .published), .existing),
            .message(Message.mock(text: "Thanks for asking 😊", sender: sender, status: .published), .existing),
        ]
        return MessagesGroup(
            id: "mock-outgoing-group",
            sender: sender,
            messages: messages,
            isLastGroup: false,
            isLastGroupSentByCurrentUser: true
        )
    }

    static var mockMixed: MessagesGroup {
        let sender = ConversationMember.mock(isCurrentUser: true)
        let messages: [AnyMessage] = [
            .message(Message.mock(text: "Here's my first message", sender: sender, status: .published), .existing),
            .message(Message.mock(text: "And another one", sender: sender, status: .published), .existing),
            .message(Message.mock(text: "This one is still sending...", sender: sender, status: .unpublished), .existing),
        ]
        return MessagesGroup(
            id: "mock-mixed-group",
            sender: sender,
            messages: messages,
            isLastGroup: true,
            isLastGroupSentByCurrentUser: true
        )
    }

    static var mockIncomingWithReactions: MessagesGroup {
        let sender = ConversationMember.mock(isCurrentUser: false)
        let reactions = [
            MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: true)),
            MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: false, name: "Alice")),
            MessageReaction.mock(emoji: "🧠", sender: .mock(isCurrentUser: false, name: "Bob")),
        ]
        let messages: [AnyMessage] = [
            .message(Message.mock(text: "Hey there!", sender: sender, status: .published), .existing),
            .message(Message.mock(text: "How are you doing today?", sender: sender, status: .published, reactions: reactions), .existing),
        ]
        return MessagesGroup(
            id: "mock-incoming-reactions-group",
            sender: sender,
            messages: messages,
            isLastGroup: false,
            isLastGroupSentByCurrentUser: false
        )
    }

    static var mockOutgoingWithReactions: MessagesGroup {
        let sender = ConversationMember.mock(isCurrentUser: true)
        let reactionsNotSelected = [
            MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: false, name: "Alice")),
            MessageReaction.mock(emoji: "😂", sender: .mock(isCurrentUser: false, name: "Bob")),
        ]
        let reactionsSelected = [
            MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: true)),
            MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: false, name: "Alice")),
        ]
        let messages: [AnyMessage] = [
            .message(Message.mock(text: "I'm doing great!", sender: sender, status: .published, reactions: reactionsNotSelected), .existing),
            .message(Message.mock(text: "Thanks for asking 😊", sender: sender, status: .published, reactions: reactionsSelected), .existing),
        ]
        return MessagesGroup(
            id: "mock-outgoing-reactions-group",
            sender: sender,
            messages: messages,
            isLastGroup: false,
            isLastGroupSentByCurrentUser: true
        )
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
            .mockMixedMessages,
        ]
    }
}
