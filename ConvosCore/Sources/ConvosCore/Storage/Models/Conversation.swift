import Foundation

// MARK: - Conversation

public struct Conversation: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let clientConversationId: String
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
    /// Per-conversation UI flag set by the contacts picker when it seeds a
    /// new conversation with members. Suppresses the QR invite header in
    /// the messages list so the user doesn't see an empty-state CTA on a
    /// chat that already has members. The plus-menu "Convo code" entry
    /// still reaches the QR on demand.
    public let hidesInviteCard: Bool
    /// Per-conversation UI session flag for a host: true once the host has
    /// navigated back to home from an active invite session. While false the
    /// inline Invite/Scan card leads the transcript; once true it collapses to
    /// the regular top cell. Persisted locally so the collapse survives
    /// relaunches, and app-backgrounding does not flip it.
    public let leftHostedInviteSession: Bool
    /// True when the local user was removed from this conversation (persisted
    /// from a GroupUpdated removal, cleared when a sync proves membership
    /// again). List queries already exclude removed conversations; this
    /// surfaces the state to any view that can still reach one - e.g. it was
    /// open when the removal landed - so it renders read-only.
    public let wasRemoved: Bool
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
    public let agentJoinStatus: AgentJoinStatus?
    public let hasHadVerifiedAgent: Bool
    /// True when this conversation was created through the Agent Builder
    /// (an `AgentBuilderSummary` row exists for it). Drives the
    /// pending-agent presentation -- "New Agent" placeholder name + the
    /// add-agent avatar instead of the generic "New Convo" + emoji circle
    /// -- until a verified agent actually joins. See
    /// `isPendingAgentBuilderDraft`.
    public let wasCreatedFromAgentBuilder: Bool
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

    /// Copy of this conversation with `members` replaced. Used by the
    /// optimistic contacts-picker flows to overlay synthetic members onto
    /// a DB-emitted conversation so the chat header keeps rendering the
    /// picked end state while the real member additions are in flight.
    func withMembers(_ newMembers: [ConversationMember]) -> Conversation {
        Conversation(
            id: id,
            clientConversationId: clientConversationId,
            creator: creator,
            createdAt: createdAt,
            consent: consent,
            kind: kind,
            name: name,
            description: description,
            members: newMembers,
            otherMember: otherMember,
            messages: messages,
            isPinned: isPinned,
            isUnread: isUnread,
            isMuted: isMuted,
            pinnedOrder: pinnedOrder,
            hidesInviteCard: hidesInviteCard,
            leftHostedInviteSession: leftHostedInviteSession,
            wasRemoved: wasRemoved,
            lastMessage: lastMessage,
            imageURL: imageURL,
            imageSalt: imageSalt,
            imageNonce: imageNonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            includeInfoInPublicPreview: includeInfoInPublicPreview,
            isDraft: isDraft,
            invite: invite,
            expiresAt: expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            agentJoinStatus: agentJoinStatus,
            hasHadVerifiedAgent: hasHadVerifiedAgent,
            wasCreatedFromAgentBuilder: wasCreatedFromAgentBuilder
        )
    }

    var displayName: String {
        computedDisplayName
    }

    var computedDisplayName: String {
        computedDisplayName(memberNameOverride: { _ in nil })
    }

    /// `computedDisplayName` with an inbox → contact-name override applied
    /// to the auto-generated unnamed-group title and to DM titles. The
    /// override wins over the per-conversation profile name (mirrors
    /// `Profile`/`ConversationMember`'s override semantics). When the
    /// conversation already has an explicit `name`, it's returned verbatim
    /// — the override only affects auto-generated titles.
    /// True while an Agent-Builder-created conversation is still waiting on
    /// its verified agent to join. In this window the conversation has only
    /// the local user as a member, so it would otherwise render as the
    /// generic "New Convo" + emoji circle; instead we surface the
    /// pending-agent identity ("New Agent" + add-agent avatar) to match the
    /// builder indicator. Gated on the sticky `hasHadVerifiedAgent` flag
    /// (set once any Convos-verified agent has joined) rather than the
    /// current member list, so the hand-off to normal member-driven
    /// rendering is permanent -- a builder agent that later leaves doesn't
    /// flip the conversation back to the "New Agent" placeholder.
    var isPendingAgentBuilderDraft: Bool {
        wasCreatedFromAgentBuilder && !hasHadVerifiedAgent
    }

    func computedDisplayName(memberNameOverride: (String) -> String?) -> String {
        if let name, !name.isEmpty {
            return name
        }
        if isPendingAgentBuilderDraft {
            return "New Agent"
        }
        if kind == .dm {
            if let other = otherMember {
                return other.displayName(memberNameOverride: memberNameOverride)
            }
            return "Somebody"
        }
        let otherMembers = membersWithoutCurrent
        if otherMembers.isEmpty {
            return "New Convo"
        }
        return otherMembers.formattedNamesString(memberNameOverride: memberNameOverride)
    }

    var isFullyAnonymous: Bool {
        let otherMembers = membersWithoutCurrent
        guard !otherMembers.isEmpty else { return false }
        return !otherMembers.map(\.profile).hasAnyNamedProfile
    }

    var defaultEmoji: String {
        if let conversationEmoji, !conversationEmoji.isEmpty {
            return conversationEmoji
        }
        return EmojiSelector.emoji(for: clientConversationId)
    }

    var avatarType: ConversationAvatarType {
        // A pending agent-builder draft shows the add-agent glyph (matching
        // the builder bar / indicator) rather than the conversation emoji,
        // even before the verified agent joins. Checked before the
        // image/member branches so a user-only draft doesn't fall through
        // to the emoji circle.
        if isPendingAgentBuilderDraft {
            return .pendingAgent
        }
        if imageURL != nil {
            return .customImage
        }
        let otherMembers = membersWithoutCurrent
        if otherMembers.count == 1, let member = otherMembers.first {
            return .profile(member.profile, member.agentVerification)
        }
        if let conversationEmoji, !conversationEmoji.isEmpty {
            return .emoji(conversationEmoji)
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

    var verifiedConvosAgentCount: Int {
        members.filter(\.agentVerification.isConvosAgent).count
    }

    var hasAgent: Bool {
        agentCount > 0
    }

    var hasVerifiedConvosAgent: Bool {
        members.contains(where: \.agentVerification.isConvosAgent)
    }

    var hasEverHadVerifiedConvosAgent: Bool {
        hasHadVerifiedAgent
    }

    var hasVerifiedAgent: Bool {
        members.contains(where: \.agentVerification.isVerified)
    }

    var agentCountString: String? {
        let verified = verifiedConvosAgentCount
        let unverified = agentCount - verified
        var parts: [String] = []
        if verified > 0 {
            parts.append("\(verified) \(verified == 1 ? "Agent" : "Agents")")
        }
        if unverified > 0 {
            parts.append("\(unverified) \(unverified == 1 ? "Agent" : "Agents")")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    var shouldShowQuickEdit: Bool {
        (hasJoined && members.count <= 1) || isDraft
    }

    /// Posts a notification that the current user has left this conversation.
    func postLeftConversationNotification() {
        NotificationCenter.default.post(
            name: .leftConversationNotification,
            object: nil,
            userInfo: ["conversationId": id]
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
