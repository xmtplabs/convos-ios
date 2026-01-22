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
    public let pinnedOrder: Int?
    public let lastMessage: MessagePreview?
    public let imageURL: URL?
    public let includeInfoInPublicPreview: Bool
    public let isDraft: Bool
    public let invite: Invite?
    public let expiresAt: Date?
    public let debugInfo: ConversationDebugInfo
    public let isLocked: Bool
}

public extension Conversation {
    static let maxMembers: Int = 150

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

    var shouldShowQuickEdit: Bool {
        (hasJoined && members.count <= 1) || isDraft
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

    /// A conversation is considered full when it has reached the XMTP group limit.
    /// When full, new invites cannot be shared. Note: members can still leave, which
    /// would make space available again.
    var isFull: Bool {
        members.count >= Self.maxMembers
    }
}
