import Foundation
import GRDB

/// Pure-DB helper that flips a conversation from inactive back to active
/// when an MLS event proves the peer re-admitted the current installation.
///
/// The reactivation contract lives here (rather than on `StreamProcessor`)
/// because it is stateless, driven entirely by `DatabaseReader` /
/// `DatabaseWriter` + `ConversationLocalStateWriter`, and needs to be
/// directly testable without a live XMTP client. `StreamProcessor` holds
/// one instance and delegates after a successful conversation sync.
///
/// Callers are responsible for gating — only call `markReconnectionIfNeeded`
/// when the MLS group sync for the conversation **succeeded**. A stale
/// `group is inactive` write failure means the installation genuinely
/// can't participate yet and the `isActive` flag must stay false.
struct InactiveConversationReactivator: Sendable {
    let databaseWriter: any DatabaseWriter
    let databaseReader: any DatabaseReader
    let localStateWriter: any ConversationLocalStateWriterProtocol

    /// Maximum number of recent `update` rows back-filled with
    /// `isReconnection = true` on reactivation. Keeps the reconnection
    /// boundary visible without rewriting arbitrary amounts of history.
    static let reconnectionBackfillLimit: Int = 5

    /// Flip the conversation back to active when an incoming message
    /// proves the peer has issued an MLS commit re-admitting this
    /// installation. No-op if the conversation is already active. Tags
    /// the arriving message's update row (if any) as a reconnection and
    /// back-fills up to `reconnectionBackfillLimit` recent update rows
    /// so the UI renders the reconnection point as a visible event
    /// rather than a cliff.
    func markReconnectionIfNeeded(messageId: String, conversationId: String) async {
        do {
            guard try await isConversationInactive(conversationId: conversationId) else {
                // Already active — common when a second message lands and
                // the post-store call fires after the pre-return one
                // already flipped the flag. Trace-only so it doesn't add
                // noise on healthy conversations.
                return
            }

            // Visibility: log the moment we see an inbound on an inactive
            // conversation. Pairs with the StreamProcessor "skipping
            // reactivation — conversation sync failed" log so the
            // reactivation path is observable from launch logs.
            Log.info("InactiveConversationReactivator: reactivating \(conversationId) (messageId=\(messageId))")

            try await databaseWriter.write { db in
                if var dbMessage = try DBMessage.fetchOne(db, key: messageId),
                   var update = dbMessage.update {
                    update.isReconnection = true
                    dbMessage = dbMessage.with(update: update)
                    try dbMessage.save(db)
                }
            }

            try await markRecentUpdatesAsReconnection(conversationId: conversationId)
            try await localStateWriter.setActive(true, for: conversationId)
            Log.info("Reactivated conversation \(conversationId) after receiving message")
        } catch {
            Log.warning("markReconnectionIfNeeded failed for \(conversationId): \(error)")
        }
    }

    /// Back-fill `isReconnection = true` on the most recent
    /// `contentType == .update` rows for the conversation. Idempotent —
    /// rows already marked are left alone.
    func markRecentUpdatesAsReconnection(conversationId: String) async throws {
        try await databaseWriter.write { db in
            let sql = """
                SELECT id FROM message
                WHERE conversationId = ?
                  AND contentType = ?
                ORDER BY date DESC
                LIMIT \(Self.reconnectionBackfillLimit)
                """
            let messageIds = try String.fetchAll(
                db,
                sql: sql,
                arguments: [conversationId, MessageContentType.update.rawValue]
            )
            for messageId in messageIds {
                guard var dbMessage = try DBMessage.fetchOne(db, key: messageId),
                      var update = dbMessage.update else { continue }
                if !update.isReconnection {
                    update.isReconnection = true
                    dbMessage = dbMessage.with(update: update)
                    try dbMessage.save(db)
                }
            }
        }
    }

    private func isConversationInactive(conversationId: String) async throws -> Bool {
        try await databaseReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == conversationId)
                .filter(ConversationLocalState.Columns.isActive == false)
                .fetchOne(db) != nil
        }
    }
}
