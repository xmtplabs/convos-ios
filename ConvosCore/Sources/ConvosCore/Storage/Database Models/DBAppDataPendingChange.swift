import Foundation
import GRDB

/// A durable unit of local appData intent: the locally-merged
/// `ConversationCustomMetadata` produced by one domain's change, persisted as
/// raw protobuf bytes so the coordinator can re-apply the intent against a
/// fresh network blob after failures, restarts, or foreign commits. One row per
/// `(conversationId, domain, scopeKey)`; a newer enqueue for the same key
/// supersedes the older row.
///
/// Deliberately no foreign key to `conversation`: the creator's first appData
/// change is enqueued before the conversation row exists (the stream processor
/// publishes creator metadata ahead of persisting the conversation). Rows for
/// conversations that never materialize are dropped by the reconcile pass when
/// the group cannot be resolved.
struct DBAppDataPendingChange: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "appDataPendingChange"

    enum Columns {
        static let id: Column = Column(CodingKeys.id)
        static let seq: Column = Column(CodingKeys.seq)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let domain: Column = Column(CodingKeys.domain)
        static let scopeKey: Column = Column(CodingKeys.scopeKey)
        static let snapshot: Column = Column(CodingKeys.snapshot)
        static let attemptCount: Column = Column(CodingKeys.attemptCount)
        static let nextAttemptAt: Column = Column(CodingKeys.nextAttemptAt)
        static let lastError: Column = Column(CodingKeys.lastError)
        static let createdAt: Column = Column(CodingKeys.createdAt)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let id: String
    let seq: Int64
    let conversationId: String
    let domain: String
    let scopeKey: String?
    let snapshot: Data
    var attemptCount: Int64
    var nextAttemptAt: Date
    var lastError: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        seq: Int64,
        conversationId: String,
        domain: String,
        scopeKey: String? = nil,
        snapshot: Data,
        attemptCount: Int64 = 0,
        nextAttemptAt: Date,
        lastError: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.seq = seq
        self.conversationId = conversationId
        self.domain = domain
        self.scopeKey = scopeKey
        self.snapshot = snapshot
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
