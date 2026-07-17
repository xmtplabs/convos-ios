import Foundation
import GRDB

/// Cached canonical identity of an agent template, keyed by `templateId`.
/// Populated from `GET /api/v2/agent-templates/{id}` (see
/// `AgentTemplateCacheCoordinator`). This is the template's *published*
/// name / emoji / avatar - stable across the running instances a user has
/// in different conversations - so the contacts list can collapse those
/// instances into one row with a stable identity instead of showing
/// per-instance (and divergent) profile data.
///
/// A read-through cache, not a contact: contacts stay keyed by `inboxId`
/// in `DBContact`. Template data rarely changes, so `fetchedAt` lets the
/// coordinator decide when to refresh.
struct DBAgentTemplate: Codable, FetchableRecord, PersistableRecord, Hashable, Identifiable {
    static let databaseTableName: String = "agentTemplate"

    enum Columns {
        static let templateId: Column = Column(CodingKeys.templateId)
        static let agentName: Column = Column(CodingKeys.agentName)
        static let emoji: Column = Column(CodingKeys.emoji)
        static let avatarURL: Column = Column(CodingKeys.avatarURL)
        static let publishedURL: Column = Column(CodingKeys.publishedURL)
        static let templateDescription: Column = Column(CodingKeys.templateDescription)
        static let slug: Column = Column(CodingKeys.slug)
        static let fetchedAt: Column = Column(CodingKeys.fetchedAt)
    }

    var id: String { templateId }

    let templateId: String
    var agentName: String?
    var emoji: String?
    var avatarURL: String?
    var publishedURL: String?
    var templateDescription: String?
    var slug: String?
    var fetchedAt: Date

    enum CodingKeys: String, CodingKey {
        case templateId, agentName, emoji, avatarURL, publishedURL
        // The cache column is named `description`; the Swift property avoids
        // that name (it shadows `CustomStringConvertible.description`).
        case templateDescription = "description"
        case slug, fetchedAt
    }

    init(
        templateId: String,
        agentName: String?,
        emoji: String?,
        avatarURL: String?,
        publishedURL: String?,
        templateDescription: String?,
        slug: String?,
        fetchedAt: Date
    ) {
        self.templateId = templateId
        self.agentName = agentName
        self.emoji = emoji
        self.avatarURL = avatarURL
        self.publishedURL = publishedURL
        self.templateDescription = templateDescription
        self.slug = slug
        self.fetchedAt = fetchedAt
    }
}
