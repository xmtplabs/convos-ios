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
        // Quiesce the credits writer first: a balance refresh suspended in
        // its network call would otherwise re-insert the deleted account's
        // `credit_balance` row after the wipe below removed it.
        await CreditsServices.prepareForAccountWipe()
        try await databaseWriter.write { db in
            try SessionManager.wipeAccountScopedRows(db)
        }
        try await databaseWriter.barrierWriteWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Every log directory the wipe must empty: libxmtp's log directory
    /// and the application logger's directory (both carry inbox and
    /// account identifiers). Kept as a function so a test can verify the
    /// manifest sweeps the directory the production logger actually
    /// writes to, not just the XMTP one.
    static func logDirectoriesToSweep(environment: AppEnvironment) -> [URL] {
        [
            environment.defaultXMTPLogsDirectoryURL,
            environment.defaultApplicationLogsDirectoryURL,
        ]
    }

    /// The keychain access group the legacy-identity sweep queries. Must
    /// be the team-prefixed group the identity stores actually write under
    /// (`keychainAccessGroup`), not the bare app-group identifier: a query
    /// on the wrong group fails the entitlement check or matches nothing,
    /// silently leaving legacy identity items behind.
    static func legacyIdentitySweepAccessGroup(environment: AppEnvironment) -> String {
        environment.keychainAccessGroup
    }

    /// Persistent image caches, awaited: returns only after the disk sweep
    /// finished and throws when files (or a directory enumeration) failed,
    /// so the record is never cleared while cached images may remain.
    static func wipeImageCaches() async throws {
        try await ImageCacheContainer.shared.removeAllPersistentImagesAndWait()
    }

    /// Address-scoped SIWE JWT slot, named from the record (the identity
    /// key may already be gone). `deleteAccount` is a seam over the real
    /// keychain so tests can verify the exact slot the production auth
    /// path writes is the one deleted.
    static func wipeSiweJwtSlot(
        record: AccountDeletionRecord,
        deleteAccount: (String) throws -> Void = { try KeychainService().delete(account: $0) }
    ) throws {
        try deleteAccount(KeychainAccount.siweJwt(deviceId: record.deviceId, address: record.ethAddress))
    }

    /// Address-scoped cached backend account-id slot, named from the
    /// record.
    static func wipeSiweAccountIdSlot(
        record: AccountDeletionRecord,
        deleteAccount: (String) throws -> Void = { try KeychainService().delete(account: $0) }
    ) throws {
        try deleteAccount(KeychainAccount.siweAccountId(deviceId: record.deviceId, address: record.ethAddress))
    }

    /// Legacy device-only JWT slot, named from the record's device id.
    static func wipeLegacyJwtSlot(
        record: AccountDeletionRecord,
        deleteAccount: (String) throws -> Void = { try KeychainService().delete(account: $0) }
    ) throws {
        try deleteAccount(KeychainAccount.jwt(deviceId: record.deviceId))
    }
}
