import CryptoKit
import Foundation
import GRDB

public enum BackupError: LocalizedError {
    case restoreInProgress
    case noIdentityAvailable
    case archiveKeyGenerationFailed
    case bundleWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .restoreInProgress:
            return "A restore is currently in progress; skipping backup."
        case .noIdentityAvailable:
            return "No identity is available yet; skipping backup."
        case .archiveKeyGenerationFailed:
            return "Failed to generate a per-bundle archive key."
        case .bundleWriteFailed(let reason):
            return "Failed to write backup bundle: \(reason)"
        }
    }
}

/// Creates encrypted backup bundles for the single-inbox identity model.
///
/// A bundle contains a GRDB snapshot (`convos-single-inbox.sqlite`), a single
/// XMTP archive of the one inbox (`xmtp-archive.bin`), and inner metadata
/// that carries the per-bundle `archiveKey`. The whole thing is tarred,
/// prefixed with the `CVBD` magic header, and sealed with AES-GCM under the
/// identity's raw `databaseKey`. An unencrypted sidecar next to the bundle
/// carries only non-secret fields so `RestoreManager.findAvailableBackup`
/// can enumerate bundles without the bundle key.
public actor BackupManager {
    private let identityStore: any KeychainIdentityStoreProtocol
    private let archiveProvider: any BackupArchiveProviding
    private let databaseReader: any DatabaseReader
    private let deviceInfo: any DeviceInfoProviding
    private let environment: AppEnvironment
    private let restoreFlagDefaults: UserDefaults

    public init(
        identityStore: any KeychainIdentityStoreProtocol,
        archiveProvider: any BackupArchiveProviding,
        databaseReader: any DatabaseReader,
        deviceInfo: any DeviceInfoProviding,
        environment: AppEnvironment,
        restoreFlagSuiteName: String? = nil
    ) {
        self.identityStore = identityStore
        self.archiveProvider = archiveProvider
        self.databaseReader = databaseReader
        self.deviceInfo = deviceInfo
        self.environment = environment
        let suite = restoreFlagSuiteName ?? environment.appGroupIdentifier
        self.restoreFlagDefaults = UserDefaults(suiteName: suite) ?? .standard
    }

    /// Produces a fresh encrypted backup bundle and writes it to the backup
    /// directory (iCloud when available, app-group local otherwise). Returns
    /// the bundle URL. Idempotent — calling twice simply overwrites the
    /// previous `backup-latest.encrypted`.
    @discardableResult
    public func createBackup() async throws -> URL {
        guard !RestoreInProgressFlag.isSet(defaults: restoreFlagDefaults) else {
            Log.info("BackupManager: restore in progress, skipping")
            throw BackupError.restoreInProgress
        }

        let identitySlot = try? identityStore.loadSync()
        guard let identity = identitySlot else {
            Log.info("BackupManager: no identity yet, skipping")
            throw BackupError.noIdentityAvailable
        }

        let stagingDir = try BackupBundle.createStagingDirectory()
        var cleanedUp = false
        defer {
            if !cleanedUp {
                BackupBundle.cleanup(directory: stagingDir)
            }
        }

        // GRDB snapshot into staging. GRDB's `backup` API does a live online
        // copy that safely runs against a pool with active readers/writers.
        Log.info("BackupManager: snapshotting database")
        let dbDestination = try DatabaseQueue(path: BackupBundle.databasePath(in: stagingDir).path)
        try databaseReader.backup(to: dbDestination)

        // Per-bundle archive key. Generated fresh so compromise of a prior
        // bundle does not cascade to this one. Lives only inside the inner
        // metadata — the outer AES-GCM seal protects it end-to-end.
        let archiveKey = try Self.generateArchiveKey()

        Log.info("BackupManager: creating XMTP archive")
        let archivePath = BackupBundle.archivePath(in: stagingDir)
        let archiveStats = try await archiveProvider.createArchive(
            at: archivePath,
            encryptionKey: archiveKey
        )

        let conversationCount = try await databaseReader.read { db in
            try DBConversation.fetchCount(db)
        }

        let innerMetadata = BackupBundleMetadata(
            deviceId: deviceInfo.deviceIdentifier,
            deviceName: deviceInfo.deviceName,
            osString: deviceInfo.osString,
            conversationCount: conversationCount,
            schemaGeneration: LegacyDataWipe.currentGeneration,
            appVersion: environment.appVersion,
            archiveKey: archiveKey,
            archiveMetadata: .init(startNs: archiveStats.startNs, endNs: archiveStats.endNs)
        )
        try BackupBundleMetadata.write(innerMetadata, to: stagingDir)

        let bundleData = try BackupBundle.pack(
            directory: stagingDir,
            encryptionKey: identity.keys.databaseKey
        )
        let bundleSizeKB = bundleData.count / 1024
        Log.info(
            "BackupManager: packed bundle (\(bundleSizeKB)KB, "
            + "\(conversationCount) conversation(s))"
        )

        let outputURL = try writeToICloudOrLocal(
            bundleData: bundleData,
            sidecar: innerMetadata.sidecar
        )

        BackupBundle.cleanup(directory: stagingDir)
        cleanedUp = true
        Log.info("BackupManager: saved bundle to \(outputURL.path)")
        return outputURL
    }

    // MARK: - Helpers

    private static func generateArchiveKey() throws -> Data {
        var bytes = Data(count: 32)
        let result = bytes.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard result == errSecSuccess else {
            throw BackupError.archiveKeyGenerationFailed
        }
        return bytes
    }

    private func writeToICloudOrLocal(bundleData: Data, sidecar: BackupSidecarMetadata) throws -> URL {
        let backupDir = try resolveBackupDirectory()
        let fileManager = FileManager.default
        let bundlePath = backupDir.appendingPathComponent("backup-latest.encrypted")
        let tempBundlePath = backupDir.appendingPathComponent("backup-latest.encrypted.tmp")

        do {
            try bundleData.write(to: tempBundlePath, options: .atomic)
            if fileManager.fileExists(atPath: bundlePath.path) {
                _ = try fileManager.replaceItemAt(bundlePath, withItemAt: tempBundlePath)
            } else {
                try fileManager.moveItem(at: tempBundlePath, to: bundlePath)
            }
            try BackupSidecarMetadata.write(sidecar, to: backupDir)
            return bundlePath
        } catch {
            try? fileManager.removeItem(at: tempBundlePath)
            throw BackupError.bundleWriteFailed(error.localizedDescription)
        }
    }

    private func resolveBackupDirectory() throws -> URL {
        let deviceId = deviceInfo.deviceIdentifier
        let fileManager = FileManager.default

        if let containerId = environment.iCloudContainerIdentifier,
           let containerURL = fileManager.url(forUbiquityContainerIdentifier: containerId) {
            let backupDir = containerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true)
                .appendingPathComponent(deviceId, isDirectory: true)
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
            return backupDir
        }

        // Fallback: app-group local container. `iCloudContainerIdentifier`
        // returns nil until entitlements/provisioning land, so this is the
        // expected path today.
        let localDir = environment.defaultDatabasesDirectoryURL
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(deviceId, isDirectory: true)
        try fileManager.createDirectory(at: localDir, withIntermediateDirectories: true)
        Log.info("BackupManager: iCloud container unavailable, using local fallback")
        return localDir
    }
}
