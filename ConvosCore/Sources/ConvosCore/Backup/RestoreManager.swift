import Foundation
import GRDB
@preconcurrency import XMTPiOS

public enum RestoreState: Sendable, Equatable {
    case idle
    case decrypting
    case importingVault
    case savingKeys(completed: Int, total: Int)
    case replacingDatabase
    case importingConversations(completed: Int, total: Int)
    case completed(inboxCount: Int, failedKeyCount: Int)
    case failed(String)
}

public protocol RestoreArchiveImporter: Sendable {
    /// Import a conversation archive into a fresh XMTP client and return the
    /// installation id that was registered for this inbox on the network. The
    /// caller uses this id as the "keeper" when revoking older installations.
    func importConversationArchive(inboxId: String, path: String, encryptionKey: Data) async throws -> String
}

public protocol VaultArchiveImporter: Sendable {
    func importVaultArchive(from path: URL, encryptionKey: Data, vaultIdentity: KeychainIdentity) async throws -> [VaultKeyEntry]
}

public protocol RestoreLifecycleControlling: Sendable {
    func prepareForRestore() async
    func finishRestore() async
}

/// Closure that revokes every installation for `inboxId` except `keepInstallationId`.
/// Return value is the number of installations revoked. Default production
/// implementation wraps `XMTPInstallationRevoker`; tests pass `nil` to skip.
public typealias RestoreInstallationRevoker = @Sendable (
    _ inboxId: String,
    _ signingKey: any SigningKey,
    _ keepInstallationId: String?
) async throws -> Int

public actor RestoreManager {
    private let vaultKeyStore: VaultKeyStore
    private let vaultArchiveImporter: any VaultArchiveImporter
    private let identityStore: any KeychainIdentityStoreProtocol
    private let databaseManager: any DatabaseManagerProtocol
    private let archiveImporter: any RestoreArchiveImporter
    private let restoreLifecycleController: (any RestoreLifecycleControlling)?
    private let vaultManager: VaultManager?
    private let environment: AppEnvironment
    private let installationRevoker: RestoreInstallationRevoker?

    public private(set) var state: RestoreState = .idle

    public init(
        vaultKeyStore: VaultKeyStore,
        vaultArchiveImporter: (any VaultArchiveImporter)? = nil,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseManager: any DatabaseManagerProtocol,
        archiveImporter: any RestoreArchiveImporter,
        restoreLifecycleController: (any RestoreLifecycleControlling)? = nil,
        vaultManager: VaultManager? = nil,
        installationRevoker: RestoreInstallationRevoker? = nil,
        environment: AppEnvironment
    ) {
        self.vaultKeyStore = vaultKeyStore
        self.vaultArchiveImporter = vaultArchiveImporter ?? ConvosVaultArchiveImporter(
            vaultKeyStore: vaultKeyStore,
            environment: environment
        )
        self.identityStore = identityStore
        self.databaseManager = databaseManager
        self.archiveImporter = archiveImporter
        self.restoreLifecycleController = restoreLifecycleController
        self.vaultManager = vaultManager
        self.installationRevoker = installationRevoker
        self.environment = environment
    }

    public func restoreFromBackup(bundleURL: URL) async throws {
        state = .decrypting
        let stagingDir = try BackupBundle.createStagingDirectory()
        var preparedForRestore = false

        // Rollback state: populated once destructive operations begin, cleared once
        // the restore is committed (DB replaced + keys saved). If an error is thrown
        // before commit, we use these to restore the pre-restore state of the device.
        var xmtpStashDir: URL?
        var preRestoreIdentities: [KeychainIdentity] = []
        var committed = false

        do {
            Log.info("[Restore] reading bundle (\(bundleURL.lastPathComponent))")
            let bundleData = try Data(contentsOf: bundleURL)

            let (encryptionKey, vaultIdentity) = try await decryptBundle(
                bundleData: bundleData,
                to: stagingDir
            )
            Log.info("[Restore] decrypted with vault identity inboxId=\(vaultIdentity.inboxId)")

            let metadata = try BackupBundleMetadata.read(from: stagingDir)
            Log.info("[Restore] backup v\(metadata.version) from \(metadata.deviceName) (\(metadata.createdAt))")

            if let restoreLifecycleController {
                Log.info("[Restore] stopping sessions")
                await restoreLifecycleController.prepareForRestore()
                preparedForRestore = true
                Log.info("[Restore] sessions stopped")
            }

            Log.info("[Restore] importing vault archive and extracting keys")
            let keyEntries = try await importVaultArchive(
                encryptionKey: encryptionKey,
                vaultIdentity: vaultIdentity,
                in: stagingDir
            )
            Log.info("[Restore] extracted \(keyEntries.count) key(s) from vault archive")

            if keyEntries.isEmpty, metadata.inboxCount > 0 {
                Log.error("[Restore] backup contains \(metadata.inboxCount) conversation(s) but vault yielded 0 keys — aborting before destructive operations")
                throw RestoreError.incompleteBackup(inboxCount: metadata.inboxCount)
            }

            Log.info("[Restore] snapshotting existing keychain identities for rollback")
            preRestoreIdentities = (try? await identityStore.loadAll()) ?? []
            Log.info("[Restore] snapshotted \(preRestoreIdentities.count) identity/identities")

            Log.info("[Restore] staging local XMTP files aside")
            xmtpStashDir = try stageXMTPFiles()
            Log.info("[Restore] XMTP files staged")

            Log.info("[Restore] clearing keychain identities")
            do {
                try await identityStore.deleteAll()
            } catch {
                Log.warning("[Restore] failed to clear conversation keychain identities: \(error)")
            }

            Log.info("[Restore] saving keys to keychain")
            let failedKeyCount = await saveKeysToKeychain(entries: keyEntries)
            Log.info("[Restore] keys saved (\(failedKeyCount) failed)")
            if !keyEntries.isEmpty, failedKeyCount == keyEntries.count {
                // Every single key failed to save — keychain is empty and DB replace
                // would leave the device unable to decrypt any restored conversation.
                // Abort before touching the database.
                throw RestoreError.keychainRestoreFailed
            }

            Log.info("[Restore] replacing database")
            try replaceDatabase(from: stagingDir)
            Log.info("[Restore] database replaced")

            // Commit point: DB + keychain are consistent with the restored state.
            // The staged XMTP files are stale and can be discarded; past this point
            // any failures are non-fatal and do not roll back.
            committed = true
            if let stash = xmtpStashDir {
                deleteStagedXMTPFiles(at: stash)
                xmtpStashDir = nil
            }

            Log.info("[Restore] importing conversation archives")
            let importedInboxes = await importConversationArchives(in: stagingDir)
            Log.info("[Restore] conversation archives imported (\(importedInboxes.count) inbox(es))")

            await revokeStaleInstallationsForRestoredInboxes(importedInboxes)

            Log.info("[Restore] marking all conversations inactive")
            let localStateWriter = ConversationLocalStateWriter(databaseWriter: databaseManager.dbWriter)
            do {
                try await localStateWriter.markAllConversationsInactive()
                Log.info("[Restore] conversations marked inactive")
            } catch {
                Log.error("[Restore] failed to mark conversations inactive: \(error)")
            }

            await reCreateVault()

            if preparedForRestore {
                Log.info("[Restore] resuming sessions")
                await restoreLifecycleController?.finishRestore()
                Log.info("[Restore] sessions resumed")
            }

            let restoredCount = try countRestoredInboxes()
            state = .completed(inboxCount: restoredCount, failedKeyCount: failedKeyCount)
            Log.info("[Restore] completed: \(restoredCount) inbox(es), \(keyEntries.count) key(s), \(failedKeyCount) key failure(s)")

            BackupBundle.cleanup(directory: stagingDir)
        } catch {
            if !committed {
                Log.warning("[Restore] rolling back keychain and XMTP state after failure: \(error)")
                await rollbackKeychain(to: preRestoreIdentities)
                if let stash = xmtpStashDir {
                    restoreStagedXMTPFiles(from: stash)
                }
            }
            if preparedForRestore {
                await restoreLifecycleController?.finishRestore()
            }
            state = .failed(error.localizedDescription)
            BackupBundle.cleanup(directory: stagingDir)
            throw error
        }
    }

    // MARK: - Staging / rollback

    private func stageXMTPFiles() throws -> URL {
        let fileManager = FileManager.default
        let stashDir = fileManager.temporaryDirectory
            .appendingPathComponent("xmtp-restore-stash-\(UUID().uuidString)")
        try fileManager.createDirectory(at: stashDir, withIntermediateDirectories: true)

        let sourceDir = environment.defaultDatabasesDirectoryURL
        guard let files = try? fileManager.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return stashDir
        }

        var moved = 0
        for file in files where file.lastPathComponent.hasPrefix("xmtp-") &&
            !file.lastPathComponent.hasPrefix("xmtp-restore-stash-") {
            let destination = stashDir.appendingPathComponent(file.lastPathComponent)
            do {
                try fileManager.moveItem(at: file, to: destination)
                moved += 1
            } catch {
                Log.warning("[Restore] failed to stage XMTP file \(file.lastPathComponent): \(error)")
            }
        }
        Log.info("[Restore] staged \(moved) XMTP file(s) to \(stashDir.lastPathComponent)")
        return stashDir
    }

    private func restoreStagedXMTPFiles(from stashDir: URL) {
        let fileManager = FileManager.default
        let destinationDir = environment.defaultDatabasesDirectoryURL

        guard let files = try? fileManager.contentsOfDirectory(
            at: stashDir,
            includingPropertiesForKeys: nil
        ) else {
            try? fileManager.removeItem(at: stashDir)
            return
        }

        for file in files {
            let destination = destinationDir.appendingPathComponent(file.lastPathComponent)
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.moveItem(at: file, to: destination)
            } catch {
                Log.warning("[Restore] failed to restore staged XMTP file \(file.lastPathComponent): \(error)")
            }
        }
        try? fileManager.removeItem(at: stashDir)
        Log.info("[Restore] restored staged XMTP files")
    }

    private func deleteStagedXMTPFiles(at stashDir: URL) {
        try? FileManager.default.removeItem(at: stashDir)
    }

    private func rollbackKeychain(to snapshot: [KeychainIdentity]) async {
        do {
            try await identityStore.deleteAll()
        } catch {
            Log.warning("[Restore] rollback: failed to clear keychain before restoring snapshot: \(error)")
        }
        for identity in snapshot {
            do {
                _ = try await identityStore.save(
                    inboxId: identity.inboxId,
                    clientId: identity.clientId,
                    keys: identity.keys
                )
            } catch {
                Log.warning("[Restore] rollback: failed to restore identity \(identity.inboxId): \(error)")
            }
        }
    }

    // MARK: - Vault re-creation

    private func reCreateVault() async {
        Log.info("[Restore.reCreateVault] === START ===")

        guard let vaultManager else {
            Log.warning("[Restore.reCreateVault] no VaultManager provided, skipping vault re-creation")
            return
        }

        let vaultInboxBefore = await vaultManager.vaultInboxId ?? "nil"
        Log.info("[Restore.reCreateVault] vault inboxId before re-create: \(vaultInboxBefore)")

        Log.info("[Restore.reCreateVault] calling VaultManager.reCreate")
        do {
            try await vaultManager.reCreate(
                databaseWriter: databaseManager.dbWriter,
                environment: environment
            )
            let vaultInboxAfter = await vaultManager.vaultInboxId ?? "nil"
            Log.info("[Restore.reCreateVault] vault re-created successfully, new inboxId=\(vaultInboxAfter)")

            let keyCount = (try? await databaseManager.dbReader.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM inbox WHERE isVault = 0
                    """) ?? 0
            }) ?? 0
            Log.info("[Restore.reCreateVault] broadcasting restored conversation keys to new vault (\(keyCount) conversation inbox(es))")

            do {
                try await vaultManager.shareAllKeys()
                Log.info("[Restore.reCreateVault] broadcast complete")
            } catch {
                Log.warning("[Restore.reCreateVault] broadcast failed (non-fatal): \(error)")
            }
        } catch {
            Log.error("[Restore.reCreateVault] vault re-creation failed: \(error)")
        }

        Log.info("[Restore.reCreateVault] === DONE ===")
    }

    // MARK: - Bundle decryption

    private func decryptBundle(
        bundleData: Data,
        to stagingDir: URL
    ) async throws -> (encryptionKey: Data, identity: KeychainIdentity) {
        let identities = try await vaultKeyStore.loadAll()
        guard !identities.isEmpty else {
            throw RestoreError.noVaultKey
        }

        for identity in identities {
            let key = identity.keys.databaseKey
            do {
                Log.info("[Restore] trying vault key (inboxId=\(identity.inboxId))")
                try BackupBundle.unpack(data: bundleData, encryptionKey: key, to: stagingDir)
                Log.info("[Restore] decryption succeeded with vault key (inboxId=\(identity.inboxId))")
                return (key, identity)
            } catch {
                Log.info("[Restore] vault key (inboxId=\(identity.inboxId)) failed: \(error)")
                // Reset staging dir for the next attempt. If reset fails (e.g. disk full),
                // log and continue — let the loop try the next key, then surface
                // RestoreError.decryptionFailed at the end.
                do {
                    BackupBundle.cleanup(directory: stagingDir)
                    try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                } catch {
                    Log.warning("[Restore] failed to reset staging directory between key attempts: \(error)")
                }
            }
        }

        throw RestoreError.decryptionFailed
    }

    // MARK: - Vault archive import

    private func importVaultArchive(
        encryptionKey: Data,
        vaultIdentity: KeychainIdentity,
        in directory: URL
    ) async throws -> [VaultKeyEntry] {
        state = .importingVault
        let vaultArchivePath = BackupBundle.vaultArchivePath(in: directory)

        // Without a vault archive, we have no conversation keys to restore. Continuing
        // would wipe local state and replace the database with nothing to decrypt the
        // resulting conversations — silent data loss. Bail before any destructive op.
        guard FileManager.default.fileExists(atPath: vaultArchivePath.path) else {
            Log.error("[Restore] vault archive missing from bundle — aborting before destructive operations")
            throw RestoreError.missingVaultArchive
        }

        return try await vaultArchiveImporter.importVaultArchive(
            from: vaultArchivePath,
            encryptionKey: encryptionKey,
            vaultIdentity: vaultIdentity
        )
    }

    // MARK: - Key restoration

    @discardableResult
    private func saveKeysToKeychain(entries: [VaultKeyEntry]) async -> Int {
        var failedCount = 0
        for (index, entry) in entries.enumerated() {
            state = .savingKeys(completed: index, total: entries.count)

            do {
                let keys = try KeychainIdentityKeys(
                    privateKeyData: entry.privateKeyData,
                    databaseKey: entry.databaseKey
                )
                _ = try await identityStore.save(
                    inboxId: entry.inboxId,
                    clientId: entry.clientId,
                    keys: keys
                )
            } catch {
                failedCount += 1
                Log.warning("Failed to save key for inbox \(entry.inboxId): \(error)")
            }
        }
        state = .savingKeys(completed: entries.count, total: entries.count)
        return failedCount
    }

    // MARK: - Database replacement

    private func replaceDatabase(from directory: URL) throws {
        state = .replacingDatabase
        let backupDbPath = BackupBundle.databasePath(in: directory)

        guard FileManager.default.fileExists(atPath: backupDbPath.path) else {
            throw RestoreError.missingDatabase
        }

        try databaseManager.replaceDatabase(with: backupDbPath)
    }

    // MARK: - Conversation archive import

    /// Returns the set of `(inboxId, newInstallationId)` pairs for every
    /// conversation archive that was successfully imported. The installation id
    /// is the one registered on the XMTP network during archive import — it is
    /// the "keeper" for post-restore revocation of stale installations.
    private func importConversationArchives(in directory: URL) async -> [(inboxId: String, newInstallationId: String)] {
        let conversationsDir = directory
            .appendingPathComponent("conversations", isDirectory: true)

        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: nil
        ) else {
            Log.info("No conversation archives to import")
            return []
        }

        let archiveFiles = contents.filter { $0.pathExtension == "encrypted" }
        var completed = 0
        var imported: [(inboxId: String, newInstallationId: String)] = []

        for archiveFile in archiveFiles {
            let inboxId = archiveFile.deletingPathExtension().lastPathComponent
            state = .importingConversations(completed: completed, total: archiveFiles.count)

            let identity: KeychainIdentity
            do {
                identity = try await identityStore.identity(for: inboxId)
            } catch {
                Log.warning("No identity for conversation archive \(inboxId), skipping")
                completed += 1
                continue
            }

            do {
                let newInstallationId = try await archiveImporter.importConversationArchive(
                    inboxId: inboxId,
                    path: archiveFile.path,
                    encryptionKey: identity.keys.databaseKey
                )
                imported.append((inboxId: inboxId, newInstallationId: newInstallationId))
            } catch {
                Log.warning("Failed to import conversation archive \(inboxId): \(error)")
            }
            completed += 1
        }
        state = .importingConversations(completed: completed, total: archiveFiles.count)
        return imported
    }

    /// After a successful archive import on device B, every inbox has a brand
    /// new installation on the network (the one we just created) alongside the
    /// original installations from device A. Revoke every installation *except*
    /// the one we just created so that device A flips to `stale` on its next
    /// foreground cycle and stops diverging from the restored state.
    private func revokeStaleInstallationsForRestoredInboxes(
        _ imported: [(inboxId: String, newInstallationId: String)]
    ) async {
        guard let installationRevoker else {
            Log.info("[Restore] installationRevoker not configured, skipping post-import revocation")
            return
        }
        guard !imported.isEmpty else { return }

        Log.info("[Restore] revoking stale installations for \(imported.count) restored inbox(es)")
        for entry in imported {
            let identity: KeychainIdentity
            do {
                identity = try await identityStore.identity(for: entry.inboxId)
            } catch {
                Log.warning("[Restore] cannot load identity for \(entry.inboxId), skipping revocation: \(error)")
                continue
            }
            do {
                let revoked = try await installationRevoker(
                    entry.inboxId,
                    identity.keys.signingKey,
                    entry.newInstallationId
                )
                Log.info("[Restore] revoked \(revoked) stale installation(s) for \(entry.inboxId)")
            } catch {
                Log.warning("[Restore] revocation failed for \(entry.inboxId) (non-fatal): \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func countRestoredInboxes() throws -> Int {
        let repo = InboxesRepository(databaseReader: databaseManager.dbReader)
        return (try? repo.nonVaultUsedInboxes().count) ?? 0
    }

    // MARK: - Restore detection

    public nonisolated static func findAvailableBackup(
        environment: AppEnvironment
    ) -> (url: URL, metadata: BackupBundleMetadata)? {
        let containerId = environment.iCloudContainerIdentifier

        if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: containerId) {
            let backupsDir = containerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true)
            if let backup = findNewestBackup(in: backupsDir) {
                return backup
            }
        }

        let localBackupsDir = environment.defaultDatabasesDirectoryURL
            .appendingPathComponent("backups", isDirectory: true)
        return findNewestBackup(in: localBackupsDir)
    }

    nonisolated static func findNewestBackup(
        in backupsDir: URL
    ) -> (url: URL, metadata: BackupBundleMetadata)? {
        let fileManager = FileManager.default
        guard let deviceDirs = try? fileManager.contentsOfDirectory(
            at: backupsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var newest: (url: URL, metadata: BackupBundleMetadata)?
        for deviceDir in deviceDirs {
            guard BackupBundleMetadata.exists(in: deviceDir) else { continue }
            guard let metadata = try? BackupBundleMetadata.read(from: deviceDir) else { continue }
            let bundleURL = deviceDir.appendingPathComponent("backup-latest.encrypted")
            guard fileManager.fileExists(atPath: bundleURL.path) else { continue }

            if newest == nil || metadata.createdAt > newest?.metadata.createdAt ?? .distantPast {
                newest = (url: bundleURL, metadata: metadata)
            }
        }
        return newest
    }

    private enum RestoreError: LocalizedError {
        case noVaultKey
        case decryptionFailed
        case missingVaultArchive
        case missingDatabase
        case keychainRestoreFailed
        case incompleteBackup(inboxCount: Int)

        var errorDescription: String? {
            switch self {
            case .noVaultKey:
                return "No vault key found in keychain"
            case .decryptionFailed:
                return "None of the available vault keys could decrypt this backup"
            case .missingVaultArchive:
                return "Backup bundle does not contain a vault archive"
            case .missingDatabase:
                return "Backup bundle does not contain a database"
            case .keychainRestoreFailed:
                return "Failed to save any restored keys to the keychain"
            case .incompleteBackup(let inboxCount):
                return "Backup contains \(inboxCount) conversation(s) but the vault archive yielded no decryption keys. The backup may have been created before keys were broadcast to the vault."
            }
        }
    }
}
