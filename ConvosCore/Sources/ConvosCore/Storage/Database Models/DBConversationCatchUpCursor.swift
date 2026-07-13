import Foundation
import GRDB

/// How far a conversation's message backlog has been fetched and applied by
/// the catch-up paths (`ConversationWriter.fetchAndStoreLatestMessages` and
/// `BatchCatchUp`).
///
/// Distinct from `MAX(message.dateNs)`: message rows written by the NSE or
/// the live stream advance the newest stored message without any guarantee
/// that older backlog items were fetched. Cutting the next catch-up at
/// `MAX(message.dateNs)` therefore skipped any read receipt whose timestamp
/// fell behind a newer pushed message, permanently hiding "Read" avatars for
/// members who did read. This cursor only advances when a catch-up has
/// fetched and applied the backlog up to that point, so everything at or
/// before `caughtUpToNs` has been seen by a catch-up at least once.
struct DBConversationCatchUpCursor: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName: String = "conversation_catchup_cursors"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let caughtUpToNs: Column = Column(CodingKeys.caughtUpToNs)
    }

    let conversationId: String
    var caughtUpToNs: Int64
}

extension DBConversationCatchUpCursor {
    /// The ns timestamp the next catch-up should fetch after, or nil when no
    /// catch-up has completed for this conversation yet (callers fall back
    /// to `MAX(message.dateNs)`, the pre-cursor behavior).
    static func caughtUpToNs(for conversationId: String, in db: Database) throws -> Int64? {
        try fetchOne(db, key: conversationId)?.caughtUpToNs
    }

    /// Monotonically advance the cursor. Concurrent catch-ups (stream path
    /// and batch path) can finish out of order; never roll backwards.
    static func advance(to caughtUpToNs: Int64, for conversationId: String, in db: Database) throws {
        if let existing = try fetchOne(db, key: conversationId), existing.caughtUpToNs >= caughtUpToNs {
            return
        }
        try DBConversationCatchUpCursor(conversationId: conversationId, caughtUpToNs: caughtUpToNs)
            .save(db, onConflict: .replace)
    }
}
