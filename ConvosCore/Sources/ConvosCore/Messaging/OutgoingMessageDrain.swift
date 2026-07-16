import Foundation
import GRDB

/// Republishes outgoing messages that a dead process left behind.
///
/// The share extension stages sends durably (message rows in the shared
/// database plus media files in the app-group cache) and completes right
/// away; iOS usually suspends or kills the extension before its
/// upload-and-publish pipeline finishes. The main app calls this on every
/// foreground to push whatever got stranded through the writers' existing
/// retry machinery. It also recovers in-app sends interrupted by a
/// force-quit, which were previously lost the same way.
public enum OutgoingMessageDrain {
    /// Snapshots stuck outgoing rows and retries each one. The snapshot is
    /// taken in a single write at entry: anything already stuck belongs to a
    /// previous process, while rows created by live in-app sends can only
    /// appear after this transaction and are never touched.
    public static func drainStuckOutgoingMessages(
        databaseWriter: any DatabaseWriter,
        messagingService: any MessagingServiceProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol
    ) async {
        let cutoff = Date().addingTimeInterval(-Constant.maxAge)
        let stuck: [StuckMessage]
        do {
            stuck = try await databaseWriter.write { db in
                let rows = try DBMessage
                    .filter(Constant.stuckStatuses.map(\.rawValue).contains(DBMessage.Columns.status))
                    .filter(DBMessage.Columns.date > cutoff)
                    .fetchAll(db)
                // retryFailedMessage only accepts .failed rows; a row left
                // .unpublished by a dead process is a failure in all but name.
                for row in rows where row.status == .unpublished {
                    try row.with(status: .failed).save(db)
                }
                return rows.map { StuckMessage(clientMessageId: $0.clientMessageId, conversationId: $0.conversationId) }
            }
        } catch {
            Log.error("Outgoing drain query failed: \(error.localizedDescription)")
            return
        }
        guard !stuck.isEmpty else { return }

        Log.info("Outgoing drain: retrying \(stuck.count) stuck message(s)")
        let byConversation: [String: [StuckMessage]] = Dictionary(grouping: stuck) { $0.conversationId }
        for (conversationId, messages) in byConversation {
            let writer = messagingService.messageWriter(
                for: conversationId,
                backgroundUploadManager: backgroundUploadManager
            )
            for message in messages {
                do {
                    try await writer.retryFailedMessage(id: message.clientMessageId)
                } catch {
                    Log.warning("Outgoing drain retry failed for \(message.clientMessageId): \(error.localizedDescription)")
                }
            }
        }
    }

    private struct StuckMessage {
        let clientMessageId: String
        let conversationId: String
    }

    private enum Constant {
        static let stuckStatuses: [MessageStatus] = [.unpublished, .failed]
        /// Rows older than this stay untouched: silently re-sending
        /// long-forgotten content would surprise the sender more than help.
        static let maxAge: TimeInterval = 48 * 60 * 60
    }
}
