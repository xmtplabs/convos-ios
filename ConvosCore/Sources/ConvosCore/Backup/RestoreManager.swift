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
    private let vaultService: (any VaultServiceProtocol)?
    private let vaultArchiveImporter: any VaultArchiveImporter
    private let identityStore: any KeychainIdentityStoreProtocol
    private let databaseManager: any DatabaseManagerProtocol
    private let archiveImporter: any RestoreArchiveImporter
    private let restoreLifecycleController: (any RestoreLifecycleControlling)?
    private let environment: AppEnvironment

    public private(set) var state: RestoreState = .idle

    public init(
        vaultKeyStore: VaultKeyStore,
        vaultService: (any VaultServiceProtocol)? = nil,
        vaultArchiveImporter: (any VaultArchiveImporter)? = nil,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseManager: any DatabaseManagerProtocol,
        archiveImporter: any RestoreArchiveImporter,
        restoreLifecycleController: (any RestoreLifecycleControlling)? = nil,
        environment: AppEnvironment
    ) {
        self.vaultKeyStore = vaultKeyStore
        self.vaultService = vaultService
        self.vaultArchiveImporter = vaultArchiveImporter ?? ConvosVaultArchiveImporter(
            vaultKeyStore: vaultKeyStore,
            environment: environment
        )
        self.identityStore = identityStore
        self.databaseManager = databaseManager
        self.archiveImporter = archiveImporter
        self.restoreLifecycleController = restoreLifecycleController
        self.environment = environment
    }

    public func restoreFromBackup(bundleURL: URL) async throws {
        let vaultIdentity = try await vaultKeyStore.loadAny()
        let encryptionKey = vaultIdentity.keys.databaseKey

        state = .decrypting
        let stagingDir = try BackupBundle.createStagingDirectory()
        var preparedForRestore = false

        do {
            Log.info("[Restore] reading bundle (\(bundleURL.lastPathComponent))")
            let bundleData = try Data(contentsOf: bundleURL)
            Log.info("[Restore] unpacking bundle (\(bundleData.count) bytes)")
            try BackupBundle.unpack(data: bundleData, encryptionKey: encryptionKey, to: stagingDir)

            let metadata = try BackupBundleMetadata.read(from: stagingDir)
            Log.info("[Restore] backup v\(metadata.version) from \(metadata.deviceName) (\(metadata.createdAt))")

            Log.info("[Restore] extracting keys from live vault")
            let keyEntries = try await extractKeysFromLiveVault()
            Log.info("[Restore] extracted \(keyEntries.count) key(s)")

            if let restoreLifecycleController {
                Log.info("[Restore] preparing lifecycle (stopping sessions)")
                await restoreLifecycleController.prepareForRestore()
                preparedForRestore = true
                Log.info("[Restore] lifecycle prepared")
            }

            Log.info("[Restore] replacing database")
            try replaceDatabase(from: stagingDir)
            Log.info("[Restore] database replaced")

            Log.info("[Restore] saving keys to keychain")
            let failedKeyCount = await saveKeysToKeychain(entries: keyEntries)
            Log.info("[Restore] keys saved (\(failedKeyCount) failed)")

            Log.info("[Restore] importing conversation archives")
            await importConversationArchives(in: stagingDir)
            Log.info("[Restore] conversation archives imported")

            if preparedForRestore {
                Log.info("[Restore] finishing lifecycle (resuming sessions)")
                await restoreLifecycleController?.finishRestore()
                Log.info("[Restore] lifecycle finished")
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

    // MARK: - Vault archive import

    private func extractKeysFromLiveVault() async throws -> [VaultKeyEntry] {
        state = .importingVault

        guard let vaultManager = vaultService as? VaultManager else {
            Log.warning("[Restore] vault service unavailable, skipping key extraction")
            return []
        }

        do {
            let entries = try await vaultManager.extractKeys()
            Log.info("[Restore] extracted \(entries.count) key(s) from live vault")
            return entries
        } catch {
            Log.warning("[Restore] vault key extraction failed: \(error)")
            return []
        }
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

            if newest == nil || metadata.createdAt > newest!.metadata.createdAt {
                newest = (url: bundleURL, metadata: metadata)
            }
        }
        return newest
    }

    private enum RestoreError: LocalizedError {
        case missingVaultArchive
        case missingDatabase

        var errorDescription: String? {
            switch self {
            case .missingVaultArchive:
                return "Backup bundle does not contain a vault archive"
            case .missingDatabase:
                return "Backup bundle does not contain a database"
            }
        }
    }
}
