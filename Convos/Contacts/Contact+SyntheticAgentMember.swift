import ConvosCore
import Foundation

extension AgentShareInfo {
    /// Prefix of the sentinel inbox id carried by optimistic agent members.
    /// Lets the picker-seeding overlay tell presentation-only synthetics
    /// apart from real members (see `ConversationMember.isOptimisticAgentMember`).
    static let optimisticInboxIdPrefix: String = "optimistic-agent-"

    /// Sentinel inbox id for the optimistic agent card member. Built from the
    /// template id so it never collides with a real member's inbox id, and so
    /// the "real verified agent joined" checks can recognize and ignore it.
    func optimisticAgentInboxId() -> String {
        Self.optimisticInboxIdPrefix + (templateId ?? "pending")
    }

    /// Builds a presentation-only `ConversationMember` from this agent-share
    /// profile, scoped to the supplied draft `conversationId`. Used by
    /// `ConversationViewModel` to feed the messages-list repository's
    /// `verifiedAgent` so the existing processor synthesizes the agent
    /// contact card before the real agent has joined `conversation.members`.
    ///
    /// This member is a card vehicle only -- it is handed to the repository,
    /// never inserted into `conversation.members`, and it carries the
    /// `optimisticAgentInboxId()` sentinel so it is easy to tell apart from a
    /// real member. The emoji and description live in `Profile.metadata`
    /// (matching how a real agent profile carries them), and the verification
    /// is forced to `.verified(.convos)` so the card renders with the verified
    /// styling for the duration of the optimistic window.
    func optimisticCardMember(conversationId: String) -> ConversationMember {
        var metadata: ProfileMetadata = [:]
        if let emoji, !emoji.isEmpty {
            metadata["emoji"] = .string(emoji)
        }
        if let descriptionText, !descriptionText.isEmpty {
            metadata["description"] = .string(descriptionText)
        }
        let profile = Profile(
            inboxId: optimisticAgentInboxId(),
            conversationId: conversationId,
            name: displayName,
            avatar: avatarURL,
            isAgent: true,
            metadata: metadata.isEmpty ? nil : metadata
        )
        return ConversationMember(
            profile: profile,
            role: .member,
            isCurrentUser: false,
            isAgent: true,
            agentVerification: .verified(.convos)
        )
    }

    /// Neutral placeholder identity for the agent-template deep link, where
    /// only the template id is known at creation time. Paints a generic
    /// "Joining..." agent (no name or emoji) until the async resolve returns
    /// the real profile and upgrades it in place.
    static func neutralPendingAgent(templateId: String) -> AgentShareInfo {
        AgentShareInfo(
            templateId: templateId,
            displayName: nil,
            emoji: nil,
            descriptionText: nil,
            avatarURL: nil
        )
    }
}

extension Contact {
    /// The agent's public identity in `AgentShareInfo` form; nil for human
    /// contacts. Used by the contacts picker flows to build optimistic
    /// members for picked agents via `optimisticCardMember(conversationId:)`,
    /// so the chat header renders the agent's name and emoji before the
    /// provisioned instance joins. Mirrors the identity
    /// `ContactDetailView.confirmChatWithAgentTemplate` paints for the
    /// single-agent chat action.
    var agentShareInfo: AgentShareInfo? {
        guard let agentTemplateId else { return nil }
        return AgentShareInfo(
            templateId: agentTemplateId,
            displayName: displayName,
            emoji: profileEmoji,
            descriptionText: agentDescription,
            avatarURL: avatarURL
        )
    }
}

extension ConversationMember {
    /// True for the presentation-only optimistic agent members built by
    /// `AgentShareInfo.optimisticCardMember(conversationId:)`, recognized
    /// by their sentinel inbox id.
    var isOptimisticAgentMember: Bool {
        profile.inboxId.hasPrefix(AgentShareInfo.optimisticInboxIdPrefix)
    }

    /// The template id encoded in an optimistic agent member's sentinel
    /// inbox id. nil for real members and for the deep link's neutral
    /// placeholder (whose share info had no template id yet).
    var optimisticAgentTemplateId: String? {
        guard isOptimisticAgentMember else { return nil }
        let suffix = String(profile.inboxId.dropFirst(AgentShareInfo.optimisticInboxIdPrefix.count))
        guard !suffix.isEmpty, suffix != "pending" else { return nil }
        return suffix
    }
}

extension ConversationMember {
    /// Returns a copy with the supplied description merged into the profile
    /// metadata when the member's own profile doesn't carry one yet. Used to
    /// keep the template description on the agent contact card after the real
    /// agent joins but before it writes its `description` metadata -- a no-op
    /// when the profile already has a description or none is supplied. Like
    /// the optimistic card member, the copy is only ever handed to the
    /// messages-list repository, never inserted into `conversation.members`.
    func withFallbackAgentDescription(_ description: String?) -> ConversationMember {
        guard profile.agentDescription == nil, let description, !description.isEmpty else { return self }
        var metadata: ProfileMetadata = profile.metadata ?? [:]
        metadata["description"] = .string(description)
        let updatedProfile = Profile(
            inboxId: profile.inboxId,
            conversationId: profile.conversationId,
            name: profile.name,
            avatar: profile.avatar,
            avatarSalt: profile.avatarSalt,
            avatarNonce: profile.avatarNonce,
            avatarKey: profile.avatarKey,
            isAgent: profile.isAgent,
            imageSourceContentDigest: profile.imageSourceContentDigest,
            metadata: metadata
        )
        return ConversationMember(
            profile: updatedProfile,
            role: role,
            isCurrentUser: isCurrentUser,
            isAgent: isAgent,
            agentVerification: agentVerification,
            invitedBy: invitedBy,
            joinedAt: joinedAt
        )
    }
}
