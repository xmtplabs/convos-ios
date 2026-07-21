import Foundation
import GRDB

/// One `convos.org/brainstorm-anchor:1.0` message recorded by the receiver
/// (or by the sender at publish time). Brainstorm replies reference either a
/// thinking-moment id or one of these anchor ids; the anchor carries the
/// agent the thread belongs to so replies can be routed to that agent's
/// brainstorm tab.
///
/// `id` is the XMTP message id of the anchor message, so re-applying the
/// same event is idempotent (PK conflict on insert).
struct DBBrainstormAnchor: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName: String = "brainstormAnchor"

    var id: String
    var conversationId: String
    var agentInboxId: String
    var senderInboxId: String
    var sentAtNs: Int64

    enum Columns {
        static let id: Column = Column(CodingKeys.id)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let agentInboxId: Column = Column(CodingKeys.agentInboxId)
        static let senderInboxId: Column = Column(CodingKeys.senderInboxId)
        static let sentAtNs: Column = Column(CodingKeys.sentAtNs)
    }
}
