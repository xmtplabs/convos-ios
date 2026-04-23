import Foundation
import GRDB

/// Errors surfaced by `BackupManager.createBackup`.
public enum BackupError: Error, LocalizedError {
    case noIdentity
    case restoreInProgress
    case clientUnavailable(any Error)
    case archiveFailed(any Error)
    case writeFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case .noIdentity:
            return "No identity in the keychain — nothing to back up yet"
        case .restoreInProgress:
            return "A restore is in progress; skipping this backup"
        case let .clientUnavailable(inner):
            return "Live XMTP client unavailable for archive creation: \(inner)"
        case let .archiveFailed(inner):
            return "XMTP archive creation failed: \(inner)"
        case let .writeFailed(inner):
            return "Writing bundle to disk failed: \(inner)"
        }
    }
}

/// Orchestrates creation of a single iCloud backup bundle.
///
/// The flow, per
/// `docs/plans/icloud-backup-single-inbox.md` §"Backup flow":
///
/// 1. Skip early if `RestoreInProgressFlag` is set — a concurrent
///    backup would race the restore on shared files.
/// 2. Read the identity via `identityStore.loadSync`; skip if `nil`
///    (first launch, no inbox yet — nothing to back up).
/// 3. Snapshot the live GRDB pool into a staging file via
///    `DatabasePool.backup(to:)`. This is a consistent point-in-time
///    copy even while the main app continues to write.
/// 4. Generate a fresh 32-byte `archiveKey`, hand it to
///    `client.createArchive` to produce an XMTP archive of
///    `{conversations, messages}`.
/// 5. Write the full metadata (includes `archiveKey`) into the
///    staging directory.
/// 6. Tar + AES-GCM-seal with `identity.keys.databaseKey`.
/// 7. Atomic write to iCloud (with local fallback). Sidecar
///    metadata (no `archiveKey`) is written next to the sealed
///    bundle so `findAvailableBackup` can discover without the
///    outer-seal key.
///
/// Non-actor deliberately — `createBackup` is inherently serialized
/// by its one caller (`BackupScheduler` fires sequentially, UI
/// "Back up now" is user-driven). Concurrency protection is at the
/// call site, not inside the manager.
public final class BackupManager: @unchecked Sendable {
    public typealias ClientProvider = @Sendable () async throws -> any XMTPClientProvider

    private let databaseManager: any DatabaseManagerProtocol
    private let identityStore: any KeychainIdentityStoreProtocol
    private let clientProvider: ClientProvider
    private let environment: AppEnvironment
    private let bundleFilename: String
    private let now: @Sendable () -> Date

    public init(
        databaseManager: any DatabaseManagerProtocol,
        identityStore: any KeychainIdentityStoreProtocol,
        clientProvider: @escaping ClientProvider,
        environment: AppEnvironment,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.databaseManager = databaseManager
        self.identityStore = identityStore
        self.clientProvider = clientProvider
        self.environment = environment
        self.bundleFilename = Constant.bundleFilename
        self.now = now
    }

    /// Full create flow. Returns the URL of the sealed bundle on
    /// success (iCloud or local fallback). Throws on skip conditions
    /// and on any failure past the point of a fresh staging dir.
    @discardableResult
    public func createBackup() async throws -> URL {
        if RestoreInProgressFlag.isSet(environment: environment) {
            Log.info("createBackup: restore in progress, skipping")
            throw BackupError.restoreInProgress
        }

        let identity: KeychainIdentity
        do {
            guard let loaded = try identityStore.loadSync() else {
                Log.info("createBackup: no identity present, skipping")
                throw BackupError.noIdentity
            }
            identity = loaded
        } catch let error as BackupError {
            throw error
        } catch {
            Log.warning("createBackup: keychain loadSync failed (\(error)); skipping")
            throw BackupError.noIdentity
        }

        let staging = try BackupBundle.createStagingDirectory()
        defer { BackupBundle.cleanup(directory: staging) }

        try snapshotDatabase(to: staging)
        let archiveKey = try BackupBundleCrypto.generateArchiveKey()
        try await createXMTPArchive(at: staging, archiveKey: archiveKey)

        let metadata = try buildMetadata(archiveKey: archiveKey)
        try BackupBundleMetadata.writeFull(metadata, to: staging)

        let sealed: Data
        do {
            sealed = try BackupBundle.pack(
                directory: staging,
                encryptionKey: identity.keys.databaseKey
            )
        } catch {
            throw BackupError.writeFailed(error)
        }

        return try writeBundle(sealed: sealed, sidecar: metadata.sidecar)
    }

    // MARK: - Step helpers

    private func snapshotDatabase(to staging: URL) throws {
        let destination = BackupBundle.databasePath(in: staging)
        let destinationQueue: DatabaseQueue
        do {
            destinationQueue = try DatabaseQueue(path: destination.path)
        } catch {
            throw BackupError.writeFailed(error)
        }
        do {
            try databaseManager.dbReader.backup(to: destinationQueue)
        } catch {
            throw BackupError.writeFailed(error)
        }
    }

    private func createXMTPArchive(at staging: URL, archiveKey: Data) async throws {
        let archivePath = BackupBundle.xmtpArchivePath(in: staging).path

        let client: any XMTPClientProvider
        do {
            client = try await clientProvider()
        } catch {
            throw BackupError.clientUnavailable(error)
        }

        do {
            try await client.createArchive(
                path: archivePath,
                encryptionKey: archiveKey
            )
        } catch {
            throw BackupError.archiveFailed(error)
        }
    }

    private func buildMetadata(archiveKey: Data) throws -> BackupBundleMetadata {
        let conversationCount = (try? databaseManager.dbReader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation WHERE isUnused = 0") ?? 0
        }) ?? 0

        return BackupBundleMetadata(
            createdAt: now(),
            deviceId: DeviceInfo.deviceIdentifier,
            deviceName: DeviceInfo.deviceName,
            osString: DeviceInfo.osString,
            conversationCount: conversationCount,
            schemaGeneration: LegacyDataWipe.currentGeneration,
            appVersion: Bundle.appVersion,
            archiveKey: archiveKey
        )
    }

    private func writeBundle(
        sealed: Data,
        sidecar: BackupBundleMetadata.Sidecar
    ) throws -> URL {
        let outputDir: URL
        do {
            outputDir = try resolveBackupDirectory()
        } catch {
            throw BackupError.writeFailed(error)
        }

        let bundlePath = outputDir.appendingPathComponent(bundleFilename)
        let tempPath = outputDir.appendingPathComponent(bundleFilename + ".tmp")

        do {
            try sealed.write(to: tempPath, options: [.atomic])
            let fm = FileManager.default
            if fm.fileExists(atPath: bundlePath.path) {
                _ = try fm.replaceItemAt(bundlePath, withItemAt: tempPath)
            } else {
                try fm.moveItem(at: tempPath, to: bundlePath)
            }
            // Sidecar written *after* the bundle — `findAvailableBackup`
            // validates both exist before offering a restore, so a
            // reader that sees the new sidecar sees the new bundle too.
            try BackupBundleMetadata.writeSidecar(sidecar, to: outputDir)
        } catch {
            throw BackupError.writeFailed(error)
        }

        Log.info("createBackup: wrote bundle to \(bundlePath.path)")
        return bundlePath
    }

    private func resolveBackupDirectory() throws -> URL {
        let deviceId = DeviceInfo.deviceIdentifier
        let fm = FileManager.default

        if let iCloudURL = fm.url(forUbiquityContainerIdentifier: environment.iCloudContainerIdentifier) {
            let dir = iCloudURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true)
                .appendingPathComponent(deviceId, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        Log.warning("createBackup: iCloud container unavailable, writing locally")
        let localDir = environment.defaultDatabasesDirectoryURL
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(deviceId, isDirectory: true)
        try fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        return localDir
    }

    private enum Constant {
        static let bundleFilename: String = "backup-latest.encrypted"
    }
}
