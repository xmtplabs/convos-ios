import Foundation
import GRDB

/// One `convos.org/thinking:1.0` event recorded by the receiver. Persisted
/// so the full thinking history survives app launches and so the detail
/// view can show every intermediate "thought" the agent surfaced — not just
/// the latest label.
///
/// Each agent `start` is its own moment row; each `stop` is also a row
/// (marking the close + optional `resultMessageId`). A "session" is the
/// implicit chain of moments sharing the same `(conversationId,
/// senderInboxId, targetMessageId)` triple — the repository aggregates
/// rows into a session at read time.
///
/// `id` is the XMTP message id of the originating thinking codec message,
/// so re-applying the same event is idempotent (PK conflict on insert).
struct DBThinkingMoment: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName: String = "thinkingMoment"

    var id: String
    var conversationId: String
    var senderInboxId: String
    var targetMessageId: String
    /// "start" opens / refreshes the session; "stop" closes it. Persisted as
    /// a string so SQLite can sort/index it without bridging through a Swift
    /// enum at the DB layer.
    var state: String
    var content: String
    var sentAtNs: Int64
    var resultMessageId: String?

    enum Columns {
        static let id: Column = Column(CodingKeys.id)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let senderInboxId: Column = Column(CodingKeys.senderInboxId)
        static let targetMessageId: Column = Column(CodingKeys.targetMessageId)
        static let state: Column = Column(CodingKeys.state)
        static let content: Column = Column(CodingKeys.content)
        static let sentAtNs: Column = Column(CodingKeys.sentAtNs)
        static let resultMessageId: Column = Column(CodingKeys.resultMessageId)
    }
}
