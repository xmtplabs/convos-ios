import CryptoKit
import Foundation
import GRDB

public enum BackupError: LocalizedError {
    case restoreInProgress
    case noIdentityAvailable
    case noConversationsToBackUp
    case archiveKeyGenerationFailed
    case currentInstallationRevoked
    case backupKeyMissing
    case bundleWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .restoreInProgress:
            return "A restore is currently in progress; skipping backup."
        case .noIdentityAvailable:
            return "No identity is available yet; skipping backup."
        case .noConversationsToBackUp:
            return "No conversations to back up yet."
        case .archiveKeyGenerationFailed:
            return "Failed to generate a per-bundle archive key."
        case .currentInstallationRevoked:
            return "This device has been replaced; skipping backup."
        case .backupKeyMissing:
            return "Backup key missing from synced keychain slot — migration may not have run yet."
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

        // No point in sealing an empty bundle. Fresh installs and any
        // install whose conversations have all been explicitly deleted
        // hit this path — skip rather than producing a bundle the user
        // would have no reason to restore (and that would overwrite the
        // last-good backup in iCloud). Draft / unused rows (created
        // optimistically by UnusedConversationCache but never sent to)
        // don't count — a user with nothing but prepared-but-unsent
        // groups hasn't actually started using the app yet.
        let conversationCount = try await databaseReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.isUnused == false)
                .fetchCount(db)
        }
        guard conversationCount > 0 else {
            Log.info("BackupManager: no usable conversations to back up, skipping")
            throw BackupError.noConversationsToBackUp
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

        // Strip draft / unused rows from the snapshot. Prewarm may have
        // created a DBConversation row with isUnused = true that the
        // user never sent to. Shipping it across devices makes the
        // restore show an empty placeholder conversation that can't
        // reactivate — better to just not include it.
        try await dbDestination.write { db in
            try DBConversation
                .filter(DBConversation.Columns.isUnused == true)
                .deleteAll(db)
        }

        // Preflight: bail before doing the expensive snapshot+archive
        // work if this device's installation has already been revoked
        // from another device. The post-archive recheck below catches
        // the rare race where revocation lands during createArchive.
        let installationId = try await archiveProvider.currentInstallationId()
        let preflightActive = await XMTPInstallationStateChecker.isInstallationActive(
            inboxId: identity.inboxId,
            installationId: installationId,
            environment: environment
        )
        guard preflightActive else {
            Log.warning("BackupManager: current installation is revoked (preflight), skipping backup")
            throw BackupError.currentInstallationRevoked
        }

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

        let installationIsActive = await XMTPInstallationStateChecker.isInstallationActive(
            inboxId: identity.inboxId,
            installationId: archiveStats.installationId,
            environment: environment
        )
        guard installationIsActive else {
            Log.warning("BackupManager: current installation is revoked (post-archive), skipping backup write")
            throw BackupError.currentInstallationRevoked
        }

        // Two-key model: the bundle's outer seal uses the synced
        // `backupKey` (not the per-device `identity.databaseKey`), and
        // the inner metadata carries the source identity so the
        // destination device can adopt it on restore. See
        // `docs/plans/single-inbox-two-key-model.md`.
        guard let backupKey = try await identityStore.loadBackupKeySync() else {
            // Should never happen post-migration — KeychainLayoutMigrator
            // generates the backup key on first run.
            Log.error("BackupManager: backup key missing from synced keychain slot — refusing to write")
            throw BackupError.backupKeyMissing
        }
        let identityPayload = try JSONEncoder().encode(identity)

        let innerMetadata = BackupBundleMetadata(
            deviceId: deviceInfo.deviceIdentifier,
            deviceName: deviceInfo.deviceName,
            osString: deviceInfo.osString,
            conversationCount: conversationCount,
            schemaGeneration: LegacyDataWipe.currentGeneration,
            appVersion: environment.appVersion,
            archiveKey: archiveKey,
            archiveMetadata: .init(startNs: archiveStats.startNs, endNs: archiveStats.endNs),
            identityPayload: identityPayload
        )
        try BackupBundleMetadata.write(innerMetadata, to: stagingDir)

        let bundleData = try BackupBundle.pack(
            directory: stagingDir,
            encryptionKey: backupKey
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

        // Nudge iCloud Keychain to push the identity now. The bundle is
        // useless without the matching `databaseKey`; if the key hasn't
        // synced to a paired device by the time the bundle does, restore
        // sits in `awaitIdentityWithTimeout` until iCloud Keychain
        // catches up. Re-writing the slot triggers a CKKS push so the
        // two arrive together.
        do {
            try await identityStore.nudgeICloudSync()
        } catch {
            Log.warning("BackupManager: nudgeICloudSync failed (non-fatal): \(error)")
        }

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
