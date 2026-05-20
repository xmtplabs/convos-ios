import Foundation
import GRDB

/// Local-only record. Persists the AssistantBuilderSummary the iOS app
/// captured at Make time so it survives navigating away from the conversation
/// or quitting the app — without this row, a returning user would see the
/// natural pre-Make assistant hello + their own prompt messages instead of
/// the polished summary card.
public struct DBAssistantBuilderSummary: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName: String = "assistantBuilderSummary"

    public enum Columns {
        public static let conversationId: Column = Column(CodingKeys.conversationId)
        public static let summaryId: Column = Column(CodingKeys.summaryId)
        public static let prompt: Column = Column(CodingKeys.prompt)
        public static let attachmentsJSON: Column = Column(CodingKeys.attachmentsJSON)
        public static let createdAt: Column = Column(CodingKeys.createdAt)
        public static let cutoffDate: Column = Column(CodingKeys.cutoffDate)
        public static let bundledMessageIdsJSON: Column = Column(CodingKeys.bundledMessageIdsJSON)
    }

    public let conversationId: String
    public let summaryId: String
    public let prompt: String
    /// JSON-encoded `[AssistantBuilderSummaryAttachment]`. Photo / video
    /// thumbnails are base64-encoded `Data` inside the JSON — base64 inflates
    /// payload by ~33% but keeps the schema flat. Per-row cap is ~8
    /// attachments so a worst-case row stays under a megabyte.
    public let attachmentsJSON: String
    public let createdAt: Date
    public let cutoffDate: Date
    /// JSON-encoded `[String]` of the `clientMessageId`s of every send the
    /// builder issued on the user's behalf (prompt text, multi-remote
    /// attachment bundle, …). The processor filters these out of the chat
    /// feed by id so they don't render beside the summary card. Stored as a
    /// JSON array (not a Set) for portability; the model layer rehydrates
    /// into a Set for O(1) lookups.
    public let bundledMessageIdsJSON: String

    public init(
        conversationId: String,
        summaryId: String,
        prompt: String,
        attachmentsJSON: String,
        createdAt: Date,
        cutoffDate: Date,
        bundledMessageIdsJSON: String
    ) {
        self.conversationId = conversationId
        self.summaryId = summaryId
        self.prompt = prompt
        self.attachmentsJSON = attachmentsJSON
        self.createdAt = createdAt
        self.cutoffDate = cutoffDate
        self.bundledMessageIdsJSON = bundledMessageIdsJSON
    }
}
