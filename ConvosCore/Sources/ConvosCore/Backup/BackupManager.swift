import Foundation
import GRDB

public enum BackupError: LocalizedError {
    case broadcastKeysFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case .broadcastKeysFailed(let error):
            return "Failed to broadcast conversation keys to vault: \(error.localizedDescription)"
        }
    }
}

public struct ConversationArchiveResult: Sendable {
    public let inboxId: String
    public let success: Bool
    public let error: (any Error)?
}

public protocol BackupArchiveProvider: Sendable {
    func broadcastKeysToVault() async throws
    func createVaultArchive(at path: URL, encryptionKey: Data) async throws
    func createConversationArchive(inboxId: String, at path: String, encryptionKey: Data) async throws
}

public actor BackupManager {
    private let vaultKeyStore: VaultKeyStore
    private let archiveProvider: any BackupArchiveProvider
    private let identityStore: any KeychainIdentityStoreProtocol
    private let databaseReader: any DatabaseReader
    private let environment: AppEnvironment

    public init(
        vaultKeyStore: VaultKeyStore,
        archiveProvider: any BackupArchiveProvider,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) {
        self.vaultKeyStore = vaultKeyStore
        self.archiveProvider = archiveProvider
        self.identityStore = identityStore
        self.databaseReader = databaseReader
        self.environment = environment
    }

    public func createBackup() async throws -> URL {
        let vaultIdentity = try await vaultKeyStore.loadAny()
        let encryptionKey = vaultIdentity.keys.databaseKey

        let stagingDir = try BackupBundle.createStagingDirectory()

        do {
            let (bundleData, metadata) = try await createBundleData(
                encryptionKey: encryptionKey,
                stagingDir: stagingDir
            )

            let outputURL = try writeToICloudOrLocal(bundleData: bundleData, metadata: metadata)
            Log.info("[Backup] saved to \(outputURL.path)")
            BackupBundle.cleanup(directory: stagingDir)
            return outputURL
        } catch {
            BackupBundle.cleanup(directory: stagingDir)
            throw error
        }
    }

    private func createBundleData(
        encryptionKey: Data,
        stagingDir: URL
    ) async throws -> (Data, BackupBundleMetadata) {
        Log.info("[Backup] broadcasting all conversation keys to vault")
        do {
            try await archiveProvider.broadcastKeysToVault()
            Log.info("[Backup] keys broadcast to vault")
        } catch {
            // Fail loud: if we can't broadcast keys to the vault, the archive may not
            // contain every inbox's key. That would produce a backup that silently
            // cannot be fully restored. Better to surface the failure now than create
            // an incomplete bundle the user trusts.
            Log.error("[Backup] failed to broadcast keys to vault: \(error)")
            throw BackupError.broadcastKeysFailed(error)
        }
        Log.info("[Backup] creating vault archive")
        try await createVaultArchive(encryptionKey: encryptionKey, in: stagingDir)
        Log.info("[Backup] vault archive created")

        Log.info("[Backup] creating conversation archives")
        let conversationResults = await createConversationArchives(in: stagingDir)
        let successCount = conversationResults.filter(\.success).count
        let failedResults = conversationResults.filter { !$0.success }
        Log.info("[Backup] conversation archives: \(successCount)/\(conversationResults.count) succeeded")
        if !failedResults.isEmpty {
            for result in failedResults {
                Log.warning("[Backup] conversation archive failed for \(result.inboxId): \(result.error?.localizedDescription ?? "unknown error")")
            }
        }

        Log.info("[Backup] copying database snapshot")
        try copyDatabase(to: stagingDir)
        Log.info("[Backup] database snapshot copied")

        let metadata = BackupBundleMetadata(
            deviceId: DeviceInfo.deviceIdentifier,
            deviceName: DeviceInfo.deviceName,
            osString: DeviceInfo.osString,
            inboxCount: successCount
        )
        try BackupBundleMetadata.write(metadata, to: stagingDir)

        let bundleData = try BackupBundle.pack(directory: stagingDir, encryptionKey: encryptionKey)
        let bundleSizeKB = bundleData.count / 1024
        Log.info("[Backup] bundle packed: \(bundleSizeKB)KB, \(successCount) conversation(s), vault=true, db=true")
        return (bundleData, metadata)
    }

    private func createVaultArchive(encryptionKey: Data, in directory: URL) async throws {
        let archivePath = BackupBundle.vaultArchivePath(in: directory)
        try await archiveProvider.createVaultArchive(at: archivePath, encryptionKey: encryptionKey)
    }

    private func createConversationArchives(in directory: URL) async -> [ConversationArchiveResult] {
        let inboxes: [Inbox]
        do {
            let repo = InboxesRepository(databaseReader: databaseReader)
            inboxes = try repo.nonVaultUsedInboxes()
        } catch {
            Log.warning("[Backup] failed to load inboxes: \(error)")
            return []
        }

        var results: [ConversationArchiveResult] = []
        for inbox in inboxes {
            let identity: KeychainIdentity
            do {
                identity = try await identityStore.identity(for: inbox.inboxId)
            } catch {
                Log.warning("[Backup] no identity for inbox \(inbox.inboxId), skipping archive")
                results.append(.init(inboxId: inbox.inboxId, success: false, error: error))
                continue
            }

            let archivePath = BackupBundle.conversationArchivePath(inboxId: inbox.inboxId, in: directory)
            do {
                try await archiveProvider.createConversationArchive(
                    inboxId: inbox.inboxId,
                    at: archivePath.path,
                    encryptionKey: identity.keys.databaseKey
                )
                results.append(.init(inboxId: inbox.inboxId, success: true, error: nil))
            } catch {
                Log.warning("[Backup] failed to archive conversation \(inbox.inboxId): \(error)")
                results.append(.init(inboxId: inbox.inboxId, success: false, error: error))
            }
        }
        return results
    }

    private func copyDatabase(to directory: URL) throws {
        let destinationPath = BackupBundle.databasePath(in: directory)
        let destinationQueue = try DatabaseQueue(path: destinationPath.path)
        try databaseReader.backup(to: destinationQueue)
    }

    private func writeToICloudOrLocal(bundleData: Data, metadata: BackupBundleMetadata) throws -> URL {
        let backupDir = try resolveBackupDirectory()
        let fileManager = FileManager.default
        let bundlePath = backupDir.appendingPathComponent("backup-latest.encrypted")
        let tempBundlePath = backupDir.appendingPathComponent("backup-latest.encrypted.tmp")

        try bundleData.write(to: tempBundlePath)

        if fileManager.fileExists(atPath: bundlePath.path) {
            _ = try fileManager.replaceItemAt(bundlePath, withItemAt: tempBundlePath)
        } else {
            try fileManager.moveItem(at: tempBundlePath, to: bundlePath)
        }

        try BackupBundleMetadata.write(metadata, to: backupDir)
        return bundlePath
    }

    private func resolveBackupDirectory() throws -> URL {
        let deviceId = DeviceInfo.deviceIdentifier

        if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: environment.iCloudContainerIdentifier) {
            let backupDir = containerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true)
                .appendingPathComponent(deviceId, isDirectory: true)
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            return backupDir
        }

        let localDir = environment.defaultDatabasesDirectoryURL
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(deviceId, isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        Log.warning("[Backup] iCloud container unavailable, saved locally")
        return localDir
    }
}
