import Foundation

// MARK: - Conversation

public struct Conversation: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let clientConversationId: String
    public let inboxId: String
    public let clientId: String
    public let creator: ConversationMember
    public let createdAt: Date
    public let consent: Consent
    public let kind: ConversationKind
    public let name: String?
    public let description: String?
    public let members: [ConversationMember]
    public let otherMember: ConversationMember?
    public let messages: [Message]
    public let isPinned: Bool
    public let isUnread: Bool
    public let isMuted: Bool
    public let lastMessage: MessagePreview?
    public let imageURL: URL?
    public let isDraft: Bool
    public let invite: Invite?
    public let expiresAt: Date?
    public let debugInfo: ConversationDebugInfo
}

public extension Conversation {
    var isForked: Bool {
        debugInfo.commitLogForkStatus == .forked
    }

    var hasJoined: Bool {
        members.contains(where: { $0.isCurrentUser })
    }

    var membersWithoutCurrent: [ConversationMember] {
        members.filter { !$0.isCurrentUser }
    }

    var displayName: String {
        name.orUntitled
    }

    var memberNamesString: String {
        membersWithoutCurrent.formattedNamesString
    }

    var membersCountString: String {
        let totalCount = members.count
        return "\(totalCount) \(totalCount == 1 ? "member" : "members")"
    }

    /// Posts a notification that the current user has left this conversation.
    func postLeftConversationNotification() {
        NotificationCenter.default.post(
            name: .leftConversationNotification,
            object: nil,
            userInfo: [
                "clientId": clientId,
                "inboxId": inboxId,
                "conversationId": id
            ]
        )
    }

    var xmtpGroupTopic: String {
        id.xmtpGroupTopicFormat
    }
}
