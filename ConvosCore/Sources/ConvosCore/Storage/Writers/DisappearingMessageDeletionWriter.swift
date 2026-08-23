import Foundation
import GRDB

/// Mirrors libxmtp's disappearing-message deletions into Convos' presentation
/// database. Convos keeps its own message rows for UI composition, so removing
/// a message from libxmtp alone would otherwise leave a visible local copy.
struct DisappearingMessageDeletionWriter: Sendable {
    private let databaseWriter: any DatabaseWriter

    init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    func delete(messageId: String) async throws {
        try await delete(messageIds: [messageId], includingReferences: true)
    }

    /// Removes only the rows the user explicitly selected. Replies and
    /// reactions that reference a selected message remain untouched.
    func deleteSelectedMessages(messageIds: [String]) async throws {
        try await delete(messageIds: messageIds, includingReferences: false)
    }

    private func delete(messageIds: [String], includingReferences: Bool) async throws {
        guard !messageIds.isEmpty else { return }
        let attachmentKeys = try await databaseWriter.write { db in
            try deleteMessages(
                matching: messageIds,
                includingReferences: includingReferences,
                db: db
            )
        }
        await removeLocalArtifacts(attachmentKeys)
    }

    /// Startup / foreground safety net for deletions that occurred while no
    /// deletion stream was attached. `expiresAtNs` is computed by libxmtp and
    /// persisted on ingest, so this does not reinterpret retention settings.
    func pruneExpiredMessages(now: Date = Date()) async throws {
        let nowNs = now.nanosecondsSince1970
        let attachmentKeys = try await databaseWriter.write { db in
            let expiredIds = try String.fetchAll(
                db,
                sql: "SELECT id FROM message WHERE expiresAtNs IS NOT NULL AND expiresAtNs <= ?",
                arguments: [nowNs]
            )
            guard !expiredIds.isEmpty else { return [String]() }
            return try deleteMessages(matching: expiredIds, includingReferences: true, db: db)
        }
        await removeLocalArtifacts(attachmentKeys)
    }

    private func deleteMessages(
        matching messageIds: [String],
        includingReferences: Bool,
        db: Database
    ) throws -> [String] {
        var filter = messageIds.contains(DBMessage.Columns.id)
            || messageIds.contains(DBMessage.Columns.clientMessageId)
        if includingReferences {
            filter = filter || messageIds.contains(DBMessage.Columns.sourceMessageId)
        }
        let records = try DBMessage.filter(filter).fetchAll(db)
        guard !records.isEmpty else { return [] }

        let idsToDelete = records.map(\.id)
        let clientMessageIds = records.map(\.clientMessageId)
        let pendingUploads = try DBPendingPhotoUpload
            .filter(clientMessageIds.contains(DBPendingPhotoUpload.Columns.clientMessageId))
            .fetchAll(db)
        let attachmentKeys = records.flatMap(\.attachmentUrls) + pendingUploads.map(\.localCacheURL)

        if !attachmentKeys.isEmpty {
            try AttachmentLocalState
                .filter(attachmentKeys.contains(AttachmentLocalState.Columns.attachmentKey))
                .deleteAll(db)
        }

        try DBVoiceMemoTranscript
            .filter(idsToDelete.contains(DBVoiceMemoTranscript.Columns.messageId))
            .deleteAll(db)
        try DBPendingPhotoUpload
            .filter(clientMessageIds.contains(DBPendingPhotoUpload.Columns.clientMessageId))
            .deleteAll(db)
        try DBMessage.filter(idsToDelete.contains(DBMessage.Columns.id)).deleteAll(db)
        Log.debug("Deleted \(idsToDelete.count) local message row(s)")

        return attachmentKeys
    }

    private func removeLocalArtifacts(_ attachmentKeys: [String]) async {
        let uniqueKeys = Set(attachmentKeys)
        ImageCacheContainer.shared.removePersistentImages(for: Array(uniqueKeys))

        for key in uniqueKeys {
            if let url = URL(string: key), url.isFileURL {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                    // The cache may already have evicted the local file.
                } catch {
                    Log.warning("Failed to remove deleted message attachment: \(error)")
                }
            }

            do {
                try await FileAttachmentCache.shared.removeCachedFiles(for: key)
            } catch {
                Log.warning("Failed to remove deleted file cache: \(error)")
            }
        }
    }
}
