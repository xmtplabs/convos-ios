import Foundation

public struct MessagesGroup: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let sender: ConversationMember
    public let messages: [AnyMessage]
    public let isLastGroup: Bool
    public let isLastGroupSentByCurrentUser: Bool
    public var onlyVisibleToSender: Bool = false
    public var isLastGroupBeforeOtherMembers: Bool = false

    public var allMessages: [AnyMessage] {
        messages
    }

    public init(
        id: String,
        sender: ConversationMember,
        messages: [AnyMessage],
        isLastGroup: Bool,
        isLastGroupSentByCurrentUser: Bool,
        onlyVisibleToSender: Bool = false,
        isLastGroupBeforeOtherMembers: Bool = false
    ) {
        self.id = id
        self.sender = sender
        self.messages = messages
        self.isLastGroup = isLastGroup
        self.isLastGroupSentByCurrentUser = isLastGroupSentByCurrentUser
        self.onlyVisibleToSender = onlyVisibleToSender
        self.isLastGroupBeforeOtherMembers = isLastGroupBeforeOtherMembers
    }

    public static func == (lhs: MessagesGroup, rhs: MessagesGroup) -> Bool {
        lhs.id == rhs.id &&
        lhs.sender == rhs.sender &&
        lhs.messages == rhs.messages &&
        lhs.isLastGroup == rhs.isLastGroup &&
        lhs.isLastGroupSentByCurrentUser == rhs.isLastGroupSentByCurrentUser &&
        lhs.onlyVisibleToSender == rhs.onlyVisibleToSender &&
        lhs.isLastGroupBeforeOtherMembers == rhs.isLastGroupBeforeOtherMembers
    }
}
