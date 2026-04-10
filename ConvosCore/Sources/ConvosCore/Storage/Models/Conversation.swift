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
    public let imageSalt: Data?
    public let imageNonce: Data?
    public let imageEncryptionKey: Data?
    public let conversationEmoji: String?
    public let includeInfoInPublicPreview: Bool
    public let isDraft: Bool
    public let invite: Invite?
    public let expiresAt: Date?
    public let debugInfo: ConversationDebugInfo
    public let isLocked: Bool
    public let assistantJoinStatus: AssistantJoinStatus?
    public let hasHadVerifiedAssistant: Bool
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
        computedDisplayName
    }

    var computedDisplayName: String {
        if let name, !name.isEmpty {
            return name
        }
        if kind == .dm {
            return otherMember?.profile.displayName ?? "Somebody"
        }
        let otherMembers = membersWithoutCurrent
        if otherMembers.isEmpty {
            return "New Convo"
        }
        return otherMembers.formattedNamesString
    }

    var isFullyAnonymous: Bool {
        let otherMembers = membersWithoutCurrent
        guard !otherMembers.isEmpty else { return false }
        return !otherMembers.map(\.profile).hasAnyNamedProfile
    }

    var defaultEmoji: String {
        conversationEmoji ?? EmojiSelector.emoji(for: clientConversationId)
    }

    var avatarType: ConversationAvatarType {
        if imageURL != nil {
            return .customImage
        }
        if let conversationEmoji, !conversationEmoji.isEmpty {
            return .emoji(conversationEmoji)
        }
        let otherMembers = membersWithoutCurrent
        if otherMembers.count == 1, let member = otherMembers.first {
            return .profile(member.profile, member.agentVerification)
        }
        let otherProfiles = otherMembers.map(\.profile)
        if otherProfiles.isEmpty || !otherProfiles.hasAnyAvatar {
            return .emoji(defaultEmoji)
        }
        return .clustered(Array(otherProfiles.sortedForCluster().prefix(7)))
    }

    var memberNamesString: String {
        membersWithoutCurrent.formattedNamesString
    }

    var membersCountString: String {
        let totalCount = members.count
        return "\(totalCount) \(totalCount == 1 ? "member" : "members")"
    }

    var membersCountStringCapitalized: String {
        let totalCount = members.count
        return "\(totalCount) \(totalCount == 1 ? "Member" : "Members")"
    }

    var agentCount: Int {
        members.filter(\.isAgent).count
    }

    var verifiedAssistantCount: Int {
        members.filter(\.agentVerification.isConvosAssistant).count
    }

    var hasAgent: Bool {
        agentCount > 0
    }

    var hasVerifiedAssistant: Bool {
        members.contains(where: \.agentVerification.isConvosAssistant)
    }

    var hasEverHadVerifiedAssistant: Bool {
        hasHadVerifiedAssistant
    }

    var hasVerifiedAgent: Bool {
        members.contains(where: \.agentVerification.isVerified)
    }

    var agentCountString: String? {
        let verified = verifiedAssistantCount
        let unverified = agentCount - verified
        var parts: [String] = []
        if verified > 0 {
            parts.append("\(verified) \(verified == 1 ? "Assistant" : "Assistants")")
        }
        if unverified > 0 {
            parts.append("\(unverified) \(unverified == 1 ? "Agent" : "Agents")")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    public var hasAgentOutOfCredits: Bool {
        members.contains { $0.isAgent && $0.profile.isOutOfCredits }
    }

    public var agentOutOfCreditsProfile: Profile? {
        members.first { $0.isAgent && $0.profile.isOutOfCredits }?.profile
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

    var isPendingInvite: Bool {
        isDraft && !hasJoined
    }

    var scheduledExplosionDate: Date? {
        let now = Date()
        guard let expiresAt,
              expiresAt > now else { return nil }
        let oneYearFromNow = now.addingTimeInterval(365 * 24 * 60 * 60)
        guard expiresAt < oneYearFromNow else { return nil }
        return expiresAt
    }
}
