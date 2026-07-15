import Foundation
import GRDB

/// Individually testable bodies of wipe-manifest entries ConvosCore owns.
/// `SessionManager.makeAccountDeletionWipeExecutor` wires these; tests
/// drive them directly against mock stores and temp directories so failure
/// propagation is exercised for real, not through no-op fakes.
enum AccountDeletionWipeSteps {
    /// Primary identity keychain family: primary slot, iCloud-synced backup
    /// (deleted directly by the record's inboxId and verified, because
    /// `delete()` can no longer scope the backup once the primary slot is
    /// gone), installation marker, and consent backup. A surviving backup
    /// fails the step so the durable record stays and the next launch
    /// retries, instead of assuming the private key left iCloud.
    static func wipeKeychainIdentityFamily(
        identityStore: any KeychainIdentityStoreProtocol,
        record: AccountDeletionRecord
    ) async throws {
        try await identityStore.delete()
        try await identityStore.deleteSyncedBackup(inboxId: record.inboxId)
        let backups = try await identityStore.loadSyncedBackups()
        if backups.contains(where: { $0.inboxId == record.inboxId }) {
            throw SyncedBackupRemovalIncompleteError()
        }
    }

    /// Account-scoped GRDB rows, then compaction. The database file itself
    /// must survive (the process-wide pool holds it open), so VACUUM
    /// rewrites the file without the deleted rows' free pages and the
    /// truncating checkpoint empties the WAL so deleted content doesn't
    /// linger in convos-single-inbox.sqlite-wal.
    static func wipeDatabaseRows(databaseWriter: any DatabaseWriter) async throws {
        try await databaseWriter.write { db in
            try SessionManager.wipeAccountScopedRows(db)
        }
        try await databaseWriter.barrierWriteWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
