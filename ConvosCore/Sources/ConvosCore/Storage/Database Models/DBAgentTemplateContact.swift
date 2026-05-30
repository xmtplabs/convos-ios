import Foundation
import GRDB

/// Local agent-template contact record. Keyed by `templateId` (the backend
/// `AgentTemplate.id`), distinct from `DBContact`'s `inboxId` key: a template
/// instantiated into N conversations produces N separate agent inboxIds, so
/// the stable identity of the contact is the template, not any running
/// instance. Stores a denormalized, most-recent-wins snapshot of the template
/// profile fields observed from encountered instances.
///
/// There is no `blockedAt` column - agent-template contacts support Remove
/// only; see the agent-templates PRD.
struct DBAgentTemplateContact: Codable, FetchableRecord, PersistableRecord, Hashable, Identifiable {
    static let databaseTableName: String = "agentTemplateContact"

    enum Columns {
        static let templateId: Column = Column(CodingKeys.templateId)
        static let addedAt: Column = Column(CodingKeys.addedAt)
        static let addedViaConversationId: Column = Column(CodingKeys.addedViaConversationId)
        static let displayName: Column = Column(CodingKeys.displayName)
        static let emoji: Column = Column(CodingKeys.emoji)
        static let descriptionText: Column = Column(CodingKeys.descriptionText)
        static let publishedURL: Column = Column(CodingKeys.publishedURL)
        static let avatarURL: Column = Column(CodingKeys.avatarURL)
        static let agentVerification: Column = Column(CodingKeys.agentVerification)
        static let profileUpdatedAt: Column = Column(CodingKeys.profileUpdatedAt)
    }

    var id: String { templateId }

    let templateId: String
    let addedAt: Date
    let addedViaConversationId: String?

    var displayName: String?
    /// The template emoji. The stable visual for a non-conversation-scoped
    /// row: running-instance avatars are encrypted per-conversation and do
    /// not decode outside the conversation they belong to.
    var emoji: String?
    var descriptionText: String?
    /// The backend `publishedUrl` for the template's web page.
    var publishedURL: String?
    var avatarURL: String?
    /// Agent verification snapshot. `nil` means no agent signal observed yet.
    var agentVerification: AgentVerification?
    var profileUpdatedAt: Date?

    init(
        templateId: String,
        addedAt: Date,
        addedViaConversationId: String?,
        displayName: String? = nil,
        emoji: String? = nil,
        descriptionText: String? = nil,
        publishedURL: String? = nil,
        avatarURL: String? = nil,
        agentVerification: AgentVerification? = nil,
        profileUpdatedAt: Date? = nil
    ) {
        self.templateId = templateId
        self.addedAt = addedAt
        self.addedViaConversationId = addedViaConversationId
        self.displayName = displayName
        self.emoji = emoji
        self.descriptionText = descriptionText
        self.publishedURL = publishedURL
        self.avatarURL = avatarURL
        self.agentVerification = agentVerification
        self.profileUpdatedAt = profileUpdatedAt
    }
}

extension DBAgentTemplateContact {
    /// Returns a copy with every profile field replaced by the snapshot's
    /// values (including `nil`s) and `profileUpdatedAt` set to `timestamp`.
    /// Identity columns (`templateId`, `addedAt`, `addedViaConversationId`)
    /// are preserved. Mirrors `DBContact.replacingProfileFields(with:at:)`.
    func replacingProfileFields(
        with snapshot: AgentTemplateContactSnapshot,
        at timestamp: Date
    ) -> DBAgentTemplateContact {
        DBAgentTemplateContact(
            templateId: templateId,
            addedAt: addedAt,
            addedViaConversationId: addedViaConversationId,
            displayName: snapshot.displayName,
            emoji: snapshot.emoji,
            descriptionText: snapshot.descriptionText,
            publishedURL: snapshot.publishedURL,
            avatarURL: snapshot.avatarURL,
            agentVerification: snapshot.agentVerification,
            profileUpdatedAt: timestamp
        )
    }
}
