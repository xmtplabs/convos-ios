import Foundation
import GRDB

/// One `convos.org/thinking-control:1.0` event (a user's stop or resume
/// request for an agent's thinking session). Persisted so the detail
/// sheet's stop/resume button reflects the last action sent even across
/// app launches and devices -- the repository surfaces the latest row per
/// session as `ThinkingSessionRecord.lastControlAction`.
///
/// `id` is the XMTP message id of the originating control message, so
/// re-applying the same event (stream echo, catch-up replay) is idempotent
/// (PK conflict on insert).
struct DBThinkingControl: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName: String = "thinkingControl"

    var id: String
    var conversationId: String
    /// Inbox id of the member who sent the request.
    var senderInboxId: String
    /// Inbox id of the agent whose session the request targets. Together
    /// with `targetMessageId` this matches the thinking session key used by
    /// `ThinkingSessionRepository`.
    var agentInboxId: String
    var targetMessageId: String
    /// "stop" or "resume". Persisted as a string so SQLite can sort/index
    /// it without bridging through a Swift enum at the DB layer.
    var action: String
    var sentAtNs: Int64

    enum Columns {
        static let id: Column = Column(CodingKeys.id)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let senderInboxId: Column = Column(CodingKeys.senderInboxId)
        static let agentInboxId: Column = Column(CodingKeys.agentInboxId)
        static let targetMessageId: Column = Column(CodingKeys.targetMessageId)
        static let action: Column = Column(CodingKeys.action)
        static let sentAtNs: Column = Column(CodingKeys.sentAtNs)
    }
}
