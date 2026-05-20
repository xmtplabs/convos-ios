import Foundation

/// Presentation-layer model for an agent-template contact, hydrated from
/// `DBAgentTemplateContact`.
///
/// Keyed by `templateId` (the backend `AgentTemplate.id`) - the parallel of
/// `Contact`, which is keyed by `inboxId`. A template instantiated into many
/// conversations produces many agent inboxIds; the stable identity of the
/// contact is the template itself, so the contact is keyed by the template.
public struct AgentTemplateContact: Hashable, Identifiable, Sendable {
    public var id: String { templateId }

    public let templateId: String
    public let displayName: String?
    /// The template emoji. The stable visual for a non-conversation-scoped
    /// row, since running-instance avatars are encrypted per-conversation.
    public let emoji: String?
    public let descriptionText: String?
    /// The backend `publishedUrl`; drives the contact card's Share action.
    public let publishedURL: String?
    public let avatarURL: String?
    public let addedAt: Date
    public let addedViaConversationId: String?
    /// Last-known agent verification for this template.
    public let agentVerification: AgentVerification?

    public init(
        templateId: String,
        displayName: String?,
        emoji: String? = nil,
        descriptionText: String? = nil,
        publishedURL: String? = nil,
        avatarURL: String? = nil,
        addedAt: Date,
        addedViaConversationId: String?,
        agentVerification: AgentVerification? = nil
    ) {
        self.templateId = templateId
        self.displayName = displayName
        self.emoji = emoji
        self.descriptionText = descriptionText
        self.publishedURL = publishedURL
        self.avatarURL = avatarURL
        self.addedAt = addedAt
        self.addedViaConversationId = addedViaConversationId
        self.agentVerification = agentVerification
    }

    /// Display label that always returns something printable. Falls back to
    /// a truncated `templateId` so a browse list never renders an empty
    /// cell. Mirrors `Contact.resolvedDisplayName`.
    public var resolvedDisplayName: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        return shortTemplateId
    }

    private var shortTemplateId: String {
        guard templateId.count > 8 else { return templateId }
        return String(templateId.prefix(8))
    }
}

extension AgentTemplateContact {
    init(dbAgentTemplateContact: DBAgentTemplateContact) {
        self.init(
            templateId: dbAgentTemplateContact.templateId,
            displayName: dbAgentTemplateContact.displayName,
            emoji: dbAgentTemplateContact.emoji,
            descriptionText: dbAgentTemplateContact.descriptionText,
            publishedURL: dbAgentTemplateContact.publishedURL,
            avatarURL: dbAgentTemplateContact.avatarURL,
            addedAt: dbAgentTemplateContact.addedAt,
            addedViaConversationId: dbAgentTemplateContact.addedViaConversationId,
            agentVerification: dbAgentTemplateContact.agentVerification
        )
    }
}

extension AgentTemplateContact {
    public static func mock(
        templateId: String = UUID().uuidString,
        displayName: String? = "Sample Agent",
        emoji: String? = "🤖",
        descriptionText: String? = nil,
        publishedURL: String? = nil,
        avatarURL: String? = nil,
        addedViaConversationId: String? = nil,
        agentVerification: AgentVerification? = .verified(.convos)
    ) -> AgentTemplateContact {
        AgentTemplateContact(
            templateId: templateId,
            displayName: displayName,
            emoji: emoji,
            descriptionText: descriptionText,
            publishedURL: publishedURL,
            avatarURL: avatarURL,
            addedAt: Date(),
            addedViaConversationId: addedViaConversationId,
            agentVerification: agentVerification
        )
    }
}
