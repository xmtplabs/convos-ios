import Foundation

public extension Contact {
    /// Builds a synthetic, non-persisted contact for a tapped agent-share
    /// message card when no agent running the template is a member of the
    /// conversation. The card uses it purely for display: "New chat" spawns
    /// a fresh instance by `agentTemplateId`, and Share re-shares the link
    /// the message carried. Mirrors `Contact.suggestedAgent(_:)`.
    ///
    /// The share link itself carries no verification signal, but the resolve
    /// goes through the backend's template endpoint, so the card renders
    /// with verified-agent styling - matching the message card
    /// (`AgentShareInfo.optimisticCardMember`).
    static func agentSharePlaceholder(
        templateId: String,
        shareURL: String,
        info: AgentShareInfo?
    ) -> Contact {
        Contact(
            inboxId: agentSharePlaceholderInboxIdPrefix + templateId,
            displayName: info?.displayName,
            avatarURL: info?.avatarURL,
            addedAt: Date(timeIntervalSince1970: 0),
            addedViaConversationId: nil,
            agentVerification: .verified(.convos),
            agentTemplateId: templateId,
            agentTemplatePublishedURL: shareURL,
            profileEmoji: info?.emoji,
            agentDescription: info?.descriptionText
        )
    }

    /// Prefix stamped onto an agent-share placeholder's synthetic `inboxId`.
    /// Distinct from any real inbox so the placeholder never aliases a
    /// stored contact. Mirrors `suggestedAgentInboxIdPrefix`.
    static let agentSharePlaceholderInboxIdPrefix: String = "agent-share:"

    /// True for the synthetic contact backing a tapped agent-share card.
    var isAgentSharePlaceholder: Bool {
        inboxId.hasPrefix(Self.agentSharePlaceholderInboxIdPrefix)
    }

    /// True for any synthetic agent contact that is not a saved contact -- a
    /// suggested agent or a shared agent link. Lets surfaces suppress
    /// contact-only affordances (the "Added X ago" line, Block) for these
    /// placeholder rows.
    var isUnsavedAgentPlaceholder: Bool {
        isSuggestedAgentPlaceholder || isAgentSharePlaceholder
    }
}
