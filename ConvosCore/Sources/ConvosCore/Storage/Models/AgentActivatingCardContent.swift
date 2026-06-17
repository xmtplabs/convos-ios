import Foundation

/// Render model for the in-chat "activating agent" card shown to the creator
/// while a direct build runs (the `AgentTemplateRepository` generation is
/// `pending`/`running`/`done` but the agent hasn't joined yet). Progressively
/// filled from the poll `preview` + `progressPhrases` (PR #309 / the local
/// stub). Lives in ConvosCore so it can ride inside `MessagesListItemType`.
///
/// Identity-light by design: the avatar is the preview `emoji` (no avatar URL
/// during the build), and `agentName` / `agentDescription` are `nil` until the
/// distill preview arrives — the card renders a generic placeholder until then.
public struct AgentActivatingCardContent: Sendable, Equatable, Hashable, Identifiable {
    /// Coarse lifecycle phase the card maps to its progress + caption. Derived
    /// from the generation status so the content stays stable within a phase
    /// (the card's reveal/cycle animation isn't reset by polls).
    public enum Phase: String, Sendable, Equatable {
        /// `submitting` / `pending` — no preview yet.
        case preparing
        /// `running` — preview + phrases present; card paces the reveal.
        case generating
        /// `done` / `invited` — template exists, awaiting the agent's join.
        case finishing
    }

    /// Stable per-conversation id so the cell identity doesn't churn as the
    /// preview/progress fields fill in.
    public let id: String
    public let phase: Phase
    public let agentName: String?
    public let emoji: String?
    public let agentDescription: String?
    /// Build-narration lines, cycled by the card as the caption.
    public let progressPhrases: [String]

    public init(
        id: String,
        phase: Phase,
        agentName: String?,
        emoji: String?,
        agentDescription: String?,
        progressPhrases: [String]
    ) {
        self.id = id
        self.phase = phase
        self.agentName = agentName
        self.emoji = emoji
        self.agentDescription = agentDescription
        self.progressPhrases = progressPhrases
    }
}
