import Foundation

/// A featured ("suggested") agent template surfaced in the contacts picker's
/// "Suggested agents" section. A lightweight projection of
/// `ConvosAPI.AgentTemplate` carrying only what a picker row needs.
public struct SuggestedAgent: Identifiable, Hashable, Sendable {
    public let templateId: String
    public let name: String
    public let description: String?
    public let emoji: String?
    public let avatarURL: String?

    public var id: String { templateId }

    public init(
        templateId: String,
        name: String,
        description: String?,
        emoji: String?,
        avatarURL: String?
    ) {
        self.templateId = templateId
        self.name = name
        self.description = description
        self.emoji = emoji
        self.avatarURL = avatarURL
    }
}

public extension SuggestedAgent {
    /// Projects a backend template into a suggested agent, or `nil` when the
    /// template carries no display name -- a nameless row can't be rendered.
    init?(template: ConvosAPI.AgentTemplate) {
        guard let name = template.agentName, !name.isEmpty else { return nil }
        self.init(
            templateId: template.id,
            name: name,
            description: template.description,
            emoji: template.emoji,
            avatarURL: template.avatarUrl
        )
    }
}

/// One page of suggested agents plus the cursor for the next page (`nil` when
/// the list is exhausted).
public struct SuggestedAgentsPage: Sendable {
    public let agents: [SuggestedAgent]
    public let nextCursor: String?

    public init(agents: [SuggestedAgent], nextCursor: String?) {
        self.agents = agents
        self.nextCursor = nextCursor
    }
}

/// Fetches featured agent templates for the contacts picker's suggested
/// section. A narrow seam over `ConvosAPIClientProtocol` so the picker view
/// model can be driven by a stub in previews and tests without conforming to
/// the full API client surface.
public protocol SuggestedAgentsServiceProtocol: Sendable {
    func featuredAgents(limit: Int, cursor: String?) async throws -> SuggestedAgentsPage
}

public final class SuggestedAgentsService: SuggestedAgentsServiceProtocol {
    private let apiClient: any ConvosAPIClientProtocol

    public init(apiClient: any ConvosAPIClientProtocol) {
        self.apiClient = apiClient
    }

    public func featuredAgents(limit: Int, cursor: String?) async throws -> SuggestedAgentsPage {
        let page = try await apiClient.getFeaturedAgentTemplates(limit: limit, cursor: cursor)
        let agents = page.data.compactMap(SuggestedAgent.init(template:))
        // Collapse the cursor to nil once the backend says there is no more,
        // so callers can stop paging on `nextCursor == nil` alone.
        return SuggestedAgentsPage(agents: agents, nextCursor: page.hasMore ? page.nextCursor : nil)
    }
}

public extension Contact {
    /// Builds a synthetic, non-persisted contact representing a featured agent
    /// template in the picker's "Suggested agents" section. These never enter
    /// the contacts store: the picker uses the row purely for display and
    /// selection, and confirms by `agentTemplateId` (a fresh instance of the
    /// template is spawned into the new conversation).
    ///
    /// The list endpoint carries no verification signal, but suggested agents
    /// are first-party curated, so they intentionally render with
    /// verified-agent styling (the "Agent" pill and the agent avatar
    /// treatment). The `inboxId` is prefixed so it can never collide with a
    /// real inbox in the selection set.
    static func suggestedAgent(_ agent: SuggestedAgent) -> Contact {
        Contact(
            inboxId: suggestedAgentInboxIdPrefix + agent.templateId,
            displayName: agent.name,
            avatarURL: agent.avatarURL,
            addedAt: Date(timeIntervalSince1970: 0),
            addedViaConversationId: nil,
            agentVerification: .verified(.convos),
            agentTemplateId: agent.templateId,
            profileEmoji: agent.emoji,
            agentDescription: agent.description
        )
    }

    /// Prefix stamped onto a suggested agent's synthetic `inboxId`. Distinct
    /// from any real inbox so a selected suggestion never aliases a contact.
    static let suggestedAgentInboxIdPrefix: String = "suggested-agent:"

    /// True for the synthetic contacts backing the "Suggested agents" section
    /// -- a featured template the user hasn't added yet, not a saved contact.
    /// Lets surfaces suppress contact-only affordances (the "Added X ago"
    /// line, Block) for these placeholder rows.
    var isSuggestedAgentPlaceholder: Bool {
        inboxId.hasPrefix(Self.suggestedAgentInboxIdPrefix)
    }
}
