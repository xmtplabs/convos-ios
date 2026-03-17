import Foundation
import GRDB

public struct ConversationArchiveResult: Sendable {
    public let inboxId: String
    public let success: Bool
    public let error: (any Error)?
}

public protocol BackupArchiveProvider: Sendable {
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
        try await createVaultArchive(encryptionKey: encryptionKey, in: stagingDir)

        let conversationResults = await createConversationArchives(in: stagingDir)
        let failedResults = conversationResults.filter { !$0.success }
        if !failedResults.isEmpty {
            Log.warning("Failed to archive \(failedResults.count)/\(conversationResults.count) conversation(s)")
            for result in failedResults {
                Log.warning("  \(result.inboxId): \(result.error?.localizedDescription ?? "unknown error")")
            }
        }

        try copyDatabase(to: stagingDir)

        let successCount = conversationResults.filter(\.success).count
        let metadata = BackupBundleMetadata(
            deviceId: DeviceInfo.deviceIdentifier,
            deviceName: DeviceInfo.deviceName,
            osString: DeviceInfo.osString,
            inboxCount: successCount
        )
        try BackupBundleMetadata.write(metadata, to: stagingDir)

        let bundleData = try BackupBundle.pack(directory: stagingDir, encryptionKey: encryptionKey)
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
            inboxes = try repo.nonVaultInboxes()
        } catch {
            Log.warning("Failed to load inboxes for backup: \(error)")
            return []
        }

        var results: [ConversationArchiveResult] = []
        for inbox in inboxes {
            let identity: KeychainIdentity
            do {
                identity = try await identityStore.identity(for: inbox.inboxId)
            } catch {
                Log.warning("No identity found for inbox \(inbox.inboxId), skipping archive")
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
                Log.warning("Failed to archive conversation \(inbox.inboxId): \(error)")
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
        Log.warning("iCloud container unavailable, backup saved locally")
        return localDir
    }
}
