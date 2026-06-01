import Foundation

/// The public profile of a shared agent template, resolved from an
/// agent-share link's identifier. Just enough to render a contact card --
/// the same fields `AgentTemplateContact` exposes.
public struct AgentShareInfo: Sendable, Hashable {
    public let displayName: String?
    public let emoji: String?
    public let descriptionText: String?
    public let avatarURL: String?

    public init(
        displayName: String?,
        emoji: String?,
        descriptionText: String?,
        avatarURL: String?
    ) {
        self.displayName = displayName
        self.emoji = emoji
        self.descriptionText = descriptionText
        self.avatarURL = avatarURL
    }
}

/// Resolves an agent-share link identifier (a template id or hashed url slug)
/// to the template's public profile. The backend exposes
/// `GET /api/v2/agent-templates/:idOrHashedSlug` for this; the real
/// `ConvosAPIClient`-backed implementation is a follow-up. Until then
/// `MockAgentShareResolver` stands in so the full UI pipeline (composer chip +
/// message card) works end to end.
public protocol AgentShareResolving: Sendable {
    func resolve(identifier: String) async -> AgentShareInfo?
}

/// Deterministic stand-in resolver. Maps an identifier to one of a few sample
/// personas (stable per identifier so the same link always renders the same
/// card), with a short delay so the card's "resolving" placeholder is
/// exercised. Swap for the API-backed resolver once the iOS client method
/// lands.
public struct MockAgentShareResolver: AgentShareResolving {
    public init() {}

    public func resolve(identifier: String) async -> AgentShareInfo? {
        try? await Task.sleep(nanoseconds: 400_000_000)
        let personas = MockAgentShareResolver.personas
        let index = abs(identifier.hashValue) % personas.count
        return personas[index]
    }

    private static let personas: [AgentShareInfo] = [
        AgentShareInfo(
            displayName: "Tifoso",
            emoji: "🚴",
            descriptionText: "I'll help you plan your next ride, log mileage, and remember your favorite routes.",
            avatarURL: nil
        ),
        AgentShareInfo(
            displayName: "Sous",
            emoji: "🍳",
            descriptionText: "Your kitchen sidekick -- recipes, substitutions, and timing for everything on the stove.",
            avatarURL: nil
        ),
        AgentShareInfo(
            displayName: "Ledger",
            emoji: "📒",
            descriptionText: "I keep a running tab of shared expenses and tell you who owes what.",
            avatarURL: nil
        ),
    ]
}
