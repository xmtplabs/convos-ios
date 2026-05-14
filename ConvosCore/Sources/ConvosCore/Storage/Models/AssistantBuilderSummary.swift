import Foundation

/// In-memory, session-scoped summary of an Assistant Builder draft, captured
/// at the moment the user taps "Make". Rendered as the first cell of the
/// post-commit `MessagesListView` in place of the user's prompt messages and
/// any pre-Make assistant chatter — see `MessagesListItemType.assistantBuilderSummary`.
///
/// Not persisted: if the user navigates away and comes back, the conversation
/// shows the natural message history. This struct intentionally avoids
/// iOS-only types (no `UIImage`) so it can live in ConvosCore and be embedded
/// in `MessagesListItemType` without a circular import.
public struct AssistantBuilderSummary: Sendable, Equatable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let prompt: String
    public let attachments: [AssistantBuilderSummaryAttachment]
    public let createdAt: Date
    /// Messages with `sentAt < cutoffDate` are filtered out of the post-commit
    /// list — the summary card stands in for them.
    public let cutoffDate: Date

    public init(
        id: UUID = UUID(),
        prompt: String,
        attachments: [AssistantBuilderSummaryAttachment],
        createdAt: Date = Date(),
        cutoffDate: Date
    ) {
        self.id = id
        self.prompt = prompt
        self.attachments = attachments
        self.createdAt = createdAt
        self.cutoffDate = cutoffDate
    }
}

public enum AssistantBuilderSummaryAttachment: Sendable, Equatable, Codable, Identifiable, Hashable {
    /// Encoded thumbnail (PNG or JPEG `Data`). Decoded on the iOS side back to
    /// `UIImage` for chip rendering.
    case photo(id: UUID, thumbnailData: Data?)
    case video(id: UUID, thumbnailData: Data?)
    case file(id: UUID, filename: String, mimeType: String, fileSize: Int)
    case voiceMemo(id: UUID, duration: TimeInterval, levels: [Float])
    /// `identifier` is the raw value of the iOS-side `AssistantBuilderConnection`
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
