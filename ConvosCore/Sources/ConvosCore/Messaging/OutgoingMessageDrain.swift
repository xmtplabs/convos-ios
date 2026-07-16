import Foundation
import GRDB
import os

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
    /// Unified-log mirror so background-wake drains are visible in a tethered
    /// syslog stream (the file log is unreadable off-device).
    private static let osLog: os.Logger = os.Logger(subsystem: "org.convos.drain", category: "outbox")
    /// Snapshots stuck outgoing rows and retries each one. The snapshot is
    /// taken in a single write at entry: anything already stuck belongs to a
    /// previous process, while rows created by live in-app sends can only
    /// appear after this transaction and are never touched.
    public static func drainStuckOutgoingMessages(
        databaseWriter: any DatabaseWriter,
        messagingService: any MessagingServiceProtocol,
        backgroundUploadManager: any BackgroundUploadManagerProtocol
    ) async {
        osLog.info("drain invoked")
        let cutoff = Date().addingTimeInterval(-Constant.maxAge)
        let stuck: [StuckMessage]
        do {
            stuck = try await databaseWriter.write { db in
                // A row can be .unpublished because a live pipeline in this
                // process is still mid-upload (a background-session upload
                // resumed from the previous session, or a wake-drain firing
                // while the app is active). A fresh in-flight pending-upload
                // row identifies those; retrying them here would publish the
                // message twice.
                let liveUploadCutoff = Date().addingTimeInterval(-Constant.liveUploadWindow)
                let liveUploadMessageIds = try DBPendingPhotoUpload
                    .filter(DBPendingPhotoUpload.Columns.state == PendingUploadState.uploading.rawValue)
                    .filter(DBPendingPhotoUpload.Columns.updatedAt > liveUploadCutoff)
                    .fetchAll(db)
                    .map(\.clientMessageId)
                let rows = try DBMessage
                    .filter(Constant.stuckStatuses.map(\.rawValue).contains(DBMessage.Columns.status))
                    .filter(DBMessage.Columns.date > cutoff)
                    .order(DBMessage.Columns.date.asc)
                    .fetchAll(db)
                    .filter { !liveUploadMessageIds.contains($0.clientMessageId) }
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
        guard !stuck.isEmpty else {
            osLog.info("drain: nothing stuck")
            return
        }

        osLog.info("drain: retrying \(stuck.count, privacy: .public) stuck message(s)")
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
                    osLog.info("drain: retried \(message.clientMessageId, privacy: .public)")
                } catch {
                    osLog.error("drain: retry failed \(error.localizedDescription, privacy: .public)")
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
        /// An .uploading pending-upload row updated within this window marks
        /// its message as owned by a live pipeline, not a dead one.
        static let liveUploadWindow: TimeInterval = 60
    }
}
