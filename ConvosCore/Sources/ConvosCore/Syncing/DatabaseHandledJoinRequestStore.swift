import ConvosInvites
import Foundation
import GRDB

/// GRDB-backed handled-join-request ledger, shared between the app and the
/// notification service extension through the app-group database. Survives
/// across processing passes (`SyncingManager` builds a fresh
/// `InviteJoinRequestsManager` per batch) so an already-honored join request
/// stays inert even after its sender is removed from the group.
final class DatabaseHandledJoinRequestStore: HandledJoinRequestStoreProtocol, Sendable {
    private let databaseWriter: any DatabaseWriter

    init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    func isHandled(messageId: String) async -> Bool {
        do {
            return try await databaseWriter.read { db in
                try DBHandledJoinRequest.filter(key: messageId).fetchOne(db) != nil
            }
        } catch {
            // On a read failure fall back to the coordinator's
            // membership-based dedupe instead of dropping the request.
            Log.error("Reading handled join request \(messageId) failed: \(error)")
            return false
        }
    }

    func markHandled(messageId: String) async {
        let now = Date()
        let retentionCutoff = now.addingTimeInterval(-Constant.retention)
        do {
            try await databaseWriter.write { db in
                try DBHandledJoinRequest(messageId: messageId, handledAt: now).save(db)
                try DBHandledJoinRequest
                    .filter(DBHandledJoinRequest.Columns.handledAt < retentionCutoff)
                    .deleteAll(db)
            }
        } catch {
            Log.error("Persisting handled join request \(messageId) failed: \(error)")
        }
    }

    private enum Constant {
        /// How long handled-request rows are kept. Catch-up passes look back
        /// at most 24 hours (`InviteJoinRequestsManager.maxCatchUpWindow`),
        /// so rows older than this can never be revalidated.
        static let retention: TimeInterval = 30 * 24 * 60 * 60
    }
}
