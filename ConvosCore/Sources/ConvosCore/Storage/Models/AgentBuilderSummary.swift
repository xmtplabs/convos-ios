import Foundation

/// Summary of an Agent Builder draft, captured at the moment the user taps
/// "Make". Rendered as the first cell of the post-commit `MessagesListView`
/// in place of the user's prompt messages and any pre-Make agent chatter —
/// see `MessagesListItemType.agentBuilderSummary`.
///
/// Persisted via `DBAgentBuilderSummary` (written by `AgentBuilderSummaryWriter`
/// before any send), so a force-quit between Make and the bundle landing still
/// rehydrates the summary + its `bundledMessageIds` filter on next launch, and
/// the `AgentBuilderConnectionGrantReplayer` can fire missing grants after the
/// agent joins. This struct intentionally avoids iOS-only types (no `UIImage`)
/// so it can live in ConvosCore and be embedded in `MessagesListItemType`
/// without a circular import.
public struct AgentBuilderSummary: Sendable, Equatable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let prompt: String
    public let attachments: [AgentBuilderSummaryAttachment]
    public let createdAt: Date
    /// The moment the user tapped Make. Anchors the post-commit placeholder
    /// display window (`AgentBuilderPlaceholder.remainingDisplayTime`). No
    /// longer used to filter messages by time -- the backend now skips the
    /// agent's pre-Make greeting, and the user's own bundle is hidden by id
    /// (`bundledMessageIds` + the `BuilderBundleManifest` / local hidden rows),
    /// so the old `sentAt < cutoffDate` filter was removed.
    public let cutoffDate: Date
    /// `clientMessageId`s of the sends the builder issued on the user's behalf
    /// (prompt text + multi-remote attachment bundle today; voice memo etc.
    /// when added). `MessagesListProcessor` filters these out of the chat
    /// feed so they don't render as bare bubbles alongside the summary card.
    /// Populated synchronously by `AgentBuilderViewModel.commit()` before
    /// any writer call returns, so the messages are filtered the moment they
    /// land in the DB — no `sentAt` race.
    public let bundledMessageIds: Set<String>
    /// Captured `CloudConnection.id`s keyed by the iOS-side
    /// `AgentBuilderConnection` rawValue (e.g. "googleCalendar"). Snapshotted
    /// at the moment the user toggled the connection on (or completed the
    /// OAuth flow). Device-only connections like `appleHealth` are not present
    /// in this dictionary — they don't need an id, the enablement-store
    /// write is enough. Persisted alongside the summary so the
    /// `AgentBuilderConnectionGrantReplayer` can fire missing grants after
    /// an app death between Make and agent-join. Empty for summaries written
    /// without any cloud connections enabled.
    public let cloudConnectionIds: [String: String]
    /// Set the first time the `AgentBuilderConnectionGrantReplayer` has
    /// fully processed this summary's connections (every connection
    /// either fired successfully or was already applied). Once non-nil,
    /// the replayer skips this summary so it can't re-fire grants the
    /// user later revoked from the chat UI. `nil` for summaries that
    /// haven't reached the replayer yet (e.g. the agent hasn't joined,
    /// or this summary was written before the replayer existed).
    public let connectionsAppliedAt: Date?
    /// True when the summary belongs to a conversation the user was already in
    /// (the in-chat "New Agent" entry) rather than a fresh home-flow agent
    /// chat. The messages list keeps the conversation's invite affordances
    /// (QR / "Invite members") visible while this card shows, instead of
    /// suppressing them the way the home flow does.
    public let existingConversation: Bool

    public init(
        id: UUID = UUID(),
        prompt: String,
        attachments: [AgentBuilderSummaryAttachment],
        createdAt: Date = Date(),
        cutoffDate: Date,
        bundledMessageIds: Set<String> = [],
        cloudConnectionIds: [String: String] = [:],
        connectionsAppliedAt: Date? = nil,
        existingConversation: Bool = false
    ) {
        self.id = id
        self.prompt = prompt
        self.attachments = attachments
        self.createdAt = createdAt
        self.cutoffDate = cutoffDate
        self.bundledMessageIds = bundledMessageIds
        self.cloudConnectionIds = cloudConnectionIds
        self.connectionsAppliedAt = connectionsAppliedAt
        self.existingConversation = existingConversation
    }
}

public enum AgentBuilderSummaryAttachment: Sendable, Equatable, Codable, Identifiable, Hashable {
    /// Encoded thumbnail (PNG or JPEG `Data`). Decoded on the iOS side back to
    /// `UIImage` for chip rendering.
    case photo(id: UUID, thumbnailData: Data?)
    case video(id: UUID, thumbnailData: Data?)
    case file(id: UUID, filename: String, mimeType: String, fileSize: Int)
    case voiceMemo(id: UUID, duration: TimeInterval, levels: [Float])
    /// `identifier` is the raw value of the iOS-side `AgentBuilderConnection`
    /// enum (e.g. "appleHealth", "googleCalendar"). Stored as a string so this
    /// type doesn't need to know about the iOS enum.
    case connection(id: UUID, identifier: String)

    public var id: UUID {
        switch self {
        case .photo(let id, _),
             .video(let id, _),
             .file(let id, _, _, _),
             .voiceMemo(let id, _, _),
             .connection(let id, _):
            return id
        }
    }
}
