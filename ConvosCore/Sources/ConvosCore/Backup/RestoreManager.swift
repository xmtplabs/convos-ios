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
    func importConversationArchive(inboxId: String, path: String, encryptionKey: Data) async throws
}

public protocol VaultArchiveImporter: Sendable {
    func importVaultArchive(from path: URL, encryptionKey: Data) async throws -> [VaultKeyEntry]
}

public protocol RestoreLifecycleControlling: Sendable {
    func prepareForRestore() async
    func finishRestore() async
}

public actor RestoreManager {
    private let vaultKeyStore: VaultKeyStore
    private let vaultArchiveImporter: any VaultArchiveImporter
    private let identityStore: any KeychainIdentityStoreProtocol
    private let databaseManager: any DatabaseManagerProtocol
    private let archiveImporter: any RestoreArchiveImporter
    private let restoreLifecycleController: (any RestoreLifecycleControlling)?
    private let vaultManager: VaultManager?
    private let environment: AppEnvironment

    public private(set) var state: RestoreState = .idle

    public init(
        vaultKeyStore: VaultKeyStore,
        vaultArchiveImporter: (any VaultArchiveImporter)? = nil,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseManager: any DatabaseManagerProtocol,
        archiveImporter: any RestoreArchiveImporter,
        restoreLifecycleController: (any RestoreLifecycleControlling)? = nil,
        vaultManager: VaultManager? = nil,
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
        self.environment = environment
    }

    public func restoreFromBackup(bundleURL: URL) async throws {
        state = .decrypting
        let stagingDir = try BackupBundle.createStagingDirectory()
        var preparedForRestore = false

        do {
            Log.info("[Restore] reading bundle (\(bundleURL.lastPathComponent))")
            let bundleData = try Data(contentsOf: bundleURL)

            let (encryptionKey, _) = try await decryptBundle(
                bundleData: bundleData,
                to: stagingDir
            )

            let metadata = try BackupBundleMetadata.read(from: stagingDir)
            Log.info("[Restore] backup v\(metadata.version) from \(metadata.deviceName) (\(metadata.createdAt))")

            if let restoreLifecycleController {
                Log.info("[Restore] stopping sessions")
                await restoreLifecycleController.prepareForRestore()
                preparedForRestore = true
                Log.info("[Restore] sessions stopped")
            }

            Log.info("[Restore] importing vault archive and extracting keys")
            let keyEntries = try await importVaultArchive(encryptionKey: encryptionKey, in: stagingDir)
            Log.info("[Restore] extracted \(keyEntries.count) key(s) from vault archive")

            Log.info("[Restore] wiping local XMTP state for clean restore")
            await wipeLocalXMTPState()
            Log.info("[Restore] local XMTP state wiped")

            Log.info("[Restore] saving keys to keychain")
            let failedKeyCount = await saveKeysToKeychain(entries: keyEntries)
            Log.info("[Restore] keys saved (\(failedKeyCount) failed)")

            Log.info("[Restore] replacing database")
            try replaceDatabase(from: stagingDir)
            Log.info("[Restore] database replaced")

            Log.info("[Restore] importing conversation archives")
            await importConversationArchives(in: stagingDir)
            Log.info("[Restore] conversation archives imported")

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
            if preparedForRestore {
                await restoreLifecycleController?.finishRestore()
            }
            state = .failed(error.localizedDescription)
            BackupBundle.cleanup(directory: stagingDir)
            throw error
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

    // MARK: - Wipe

    private func wipeLocalXMTPState() async {
        try? await identityStore.deleteAll()
        Log.info("[Restore] cleared conversation keychain identities")

        // Only wipe conversation XMTP databases (AppGroup container).
        // The vault XMTP database (Documents) is preserved — it was already
        // used to extract keys and will be reconnected after restore.
        deleteXMTPFiles(in: environment.defaultDatabasesDirectoryURL)
    }

    private func deleteXMTPFiles(in directory: URL) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var count = 0
        for file in files where file.lastPathComponent.hasPrefix("xmtp-") {
            if (try? fileManager.removeItem(at: file)) != nil {
                count += 1
            }
        }
        if count > 0 {
            Log.info("[Restore] deleted \(count) XMTP file(s) from \(directory.lastPathComponent)")
        }
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

    private func importVaultArchive(encryptionKey: Data, in directory: URL) async throws -> [VaultKeyEntry] {
        state = .importingVault
        let vaultArchivePath = BackupBundle.vaultArchivePath(in: directory)

        guard FileManager.default.fileExists(atPath: vaultArchivePath.path) else {
            Log.warning("[Restore] no vault archive in bundle, skipping key extraction")
            return []
        }

        return try await vaultArchiveImporter.importVaultArchive(from: vaultArchivePath, encryptionKey: encryptionKey)
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

    private func importConversationArchives(in directory: URL) async {
        let conversationsDir = directory
            .appendingPathComponent("conversations", isDirectory: true)

        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: nil
        ) else {
            Log.info("No conversation archives to import")
            return
        }

        let archiveFiles = contents.filter { $0.pathExtension == "encrypted" }
        var completed = 0

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
                try await archiveImporter.importConversationArchive(
                    inboxId: inboxId,
                    path: archiveFile.path,
                    encryptionKey: identity.keys.databaseKey
                )
            } catch {
                Log.warning("Failed to import conversation archive \(inboxId): \(error)")
            }
            completed += 1
        }
        state = .importingConversations(completed: completed, total: archiveFiles.count)
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
            }
        }
    }
}
