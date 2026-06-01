import Foundation
import GRDB

/// The public profile of a shared agent template, resolved from an
/// agent-share link's identifier. Just enough to render a contact card --
/// the same fields `AgentTemplateContact` exposes.
public struct AgentShareInfo: Sendable, Hashable {
    /// The resolved template id (UUID). Drives opening the agent's template
    /// flow when its card is tapped -- a web-slug share only yields an id once
    /// resolved, so this is `nil` until then.
    public let templateId: String?
    public let displayName: String?
    public let emoji: String?
    public let descriptionText: String?
    public let avatarURL: String?

    public init(
        templateId: String?,
        displayName: String?,
        emoji: String?,
        descriptionText: String?,
        avatarURL: String?
    ) {
        self.templateId = templateId
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
        // Unsigned arithmetic avoids `abs(Int.min)` trapping -- `hashValue`
        // can be any `Int`, including `Int.min`.
        let index = Int(UInt(bitPattern: identifier.hashValue) % UInt(personas.count))
        return personas[index]
    }

    private static let personas: [AgentShareInfo] = [
        AgentShareInfo(
            templateId: nil,
            displayName: "Tifoso",
            emoji: "🚴",
            descriptionText: "I'll help you plan your next ride, log mileage, and remember your favorite routes.",
            avatarURL: nil
        ),
        AgentShareInfo(
            templateId: nil,
            displayName: "Sous",
            emoji: "🍳",
            descriptionText: "Your kitchen sidekick -- recipes, substitutions, and timing for everything on the stove.",
            avatarURL: nil
        ),
        AgentShareInfo(
            templateId: nil,
            displayName: "Ledger",
            emoji: "📒",
            descriptionText: "I keep a running tab of shared expenses and tell you who owes what.",
            avatarURL: nil
        ),
    ]
}

/// Resolves agent-share links against the backend's public template detail
/// endpoint (`GET /v2/agent-templates/:idOrUrlSlug`) via `ConvosAPIClient`,
/// read-through the `DBAgentTemplate` cache so a card that's already been
/// seen (here or by the contacts `AgentTemplateCacheCoordinator`) renders
/// from disk without a network round-trip. Without the cache the message
/// list re-fetched on every scroll-into-view -- the cell's resolve state is
/// per-instance and cells recycle -- so the card flashed its "Somebody" /
/// pulsing-placeholder state each time and stuck there on any fetch failure.
///
/// The real resolver `SessionManager` vends in place of `MockAgentShareResolver`.
public struct ApiAgentShareResolver: AgentShareResolving {
    private let apiClient: any ConvosAPIClientProtocol
    private let databaseReader: any DatabaseReader
    private let cacheWriter: any AgentTemplateCacheWriterProtocol

    public init(
        apiClient: any ConvosAPIClientProtocol,
        databaseReader: any DatabaseReader,
        cacheWriter: any AgentTemplateCacheWriterProtocol
    ) {
        self.apiClient = apiClient
        self.databaseReader = databaseReader
        self.cacheWriter = cacheWriter
    }

    public func resolve(identifier: String) async -> AgentShareInfo? {
        if let cached = await cachedInfo(for: identifier) {
            return cached
        }
        do {
            let template = try await apiClient.getAgentTemplate(idOrUrlSlug: identifier)
            do {
                try await cacheWriter.upsert(template, fetchedAt: Date())
            } catch {
                // Non-fatal: the resolve still returns the fetched data, but a
                // failed write means the next resolve hits the network again.
                Log.warning("ApiAgentShareResolver failed to cache \(identifier): \(error.localizedDescription)")
            }
            return AgentShareInfo(
                templateId: template.id,
                displayName: template.agentName,
                emoji: template.emoji,
                descriptionText: template.description,
                avatarURL: template.avatarUrl
            )
        } catch {
            Log.error("ApiAgentShareResolver failed to resolve \(identifier): \(error.localizedDescription)")
            return nil
        }
    }

    /// The share link's identifier is a template id or a url slug, so the
    /// cache is matched on either. A hit requires a usable identity (name or
    /// description present) so a sparse row -- e.g. one written from a publish
    /// response that carried only id/status -- still falls through to the
    /// detail fetch rather than rendering an empty card.
    private func cachedInfo(for identifier: String) async -> AgentShareInfo? {
        let row: DBAgentTemplate? = try? await databaseReader.read { db in
            try DBAgentTemplate
                .filter(
                    DBAgentTemplate.Columns.templateId == identifier
                        || DBAgentTemplate.Columns.slug == identifier
                )
                .fetchOne(db)
        }
        guard let row, row.agentName != nil || row.templateDescription != nil else {
            return nil
        }
        return AgentShareInfo(
            templateId: row.templateId,
            displayName: row.agentName,
            emoji: row.emoji,
            descriptionText: row.templateDescription,
            avatarURL: row.avatarURL
        )
    }
}
