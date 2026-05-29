import Foundation

/// Public, canonical identity of an agent template - the published name,
/// emoji, and avatar shared by every running instance of the template.
/// Read by the contacts list / picker to render one stable row per
/// template instead of per-instance profiles. Backed by the
/// `DBAgentTemplate` read-through cache.
public struct AgentTemplateInfo: Sendable, Hashable, Identifiable {
    public let templateId: String
    public let agentName: String?
    public let emoji: String?
    public let avatarURL: String?
    public let publishedURL: String?

    public var id: String { templateId }

    public init(
        templateId: String,
        agentName: String?,
        emoji: String?,
        avatarURL: String?,
        publishedURL: String?
    ) {
        self.templateId = templateId
        self.agentName = agentName
        self.emoji = emoji
        self.avatarURL = avatarURL
        self.publishedURL = publishedURL
    }
}
