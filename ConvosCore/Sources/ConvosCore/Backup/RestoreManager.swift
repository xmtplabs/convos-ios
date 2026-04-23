import Foundation
import GRDB
@preconcurrency import XMTPiOS

/// High-level progress signal for `RestoreManager.restoreFromBackup`.
/// Surfaced to the UI so the user sees where the restore is at.
public enum RestoreState: Sendable, Equatable {
    case idle
    case decrypting
    case validating
    case preparingSession
    case replacingDatabase
    case importingArchive
    case revokingStaleInstallations
    case completed
    case failed(String)
    /// Non-fatal: GRDB restore committed but XMTP archive import
    /// failed. Retry path surfaces in Settings as "Retry history
    /// import"; see CP3e for the persistence half.
    case archiveImportFailed(String)

    public static func == (lhs: RestoreState, rhs: RestoreState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.decrypting, .decrypting),
             (.validating, .validating), (.preparingSession, .preparingSession),
             (.replacingDatabase, .replacingDatabase),
             (.importingArchive, .importingArchive),
             (.revokingStaleInstallations, .revokingStaleInstallations),
             (.completed, .completed):
            return true
        case let (.failed(l), .failed(r)):
            return l == r
        case let (.archiveImportFailed(l), .archiveImportFailed(r)):
            return l == r
        default:
            return false
        }
    }
}

/// Errors surfaced by `RestoreManager.restoreFromBackup`.
public enum RestoreError: Error, LocalizedError {
    case bundleUnreadable(any Error)
    case decryptionFailed(any Error)
    case validationFailed(String)
    case identityNotAvailable
    case identityTimeout
    case schemaGenerationMismatch(bundleGeneration: String, currentGeneration: String)
    case sessionPauseFailed(any Error)
    case replaceFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case let .bundleUnreadable(error):
            return "Couldn't read the backup bundle: \(error.localizedDescription)"
        case let .decryptionFailed(error):
            return "Bundle decryption failed: \(error.localizedDescription)"
        case let .validationFailed(reason):
            return "Bundle is missing required contents: \(reason)"
        case .identityNotAvailable:
            return "No identity present in keychain — iCloud Keychain may still be syncing"
        case .identityTimeout:
            return "Timed out waiting for iCloud Keychain to provide the identity. Try again shortly."
        case let .schemaGenerationMismatch(bundle, current):
            return "This backup was made on an older version of Convos and can't be restored (bundle generation \(bundle), device generation \(current)). Try a newer backup, or start fresh."
        case let .sessionPauseFailed(error):
            return "Couldn't pause the current session for restore: \(error.localizedDescription)"
        case let .replaceFailed(error):
            return "Database replacement failed: \(error.localizedDescription)"
        }
    }
}

/// Orchestrates the read-side of the iCloud backup flow. Companion to
/// `BackupManager`.
///
/// The full flow, per
/// `docs/plans/icloud-backup-single-inbox.md` §"Restore flow":
/// 1. findAvailableBackup (sidecar read, schemaGeneration check)
/// 2. User confirms
/// 3. `awaitIdentityWithTimeout` — iCloud Keychain may lag
/// 4. Read + decrypt + untar → staging
/// 5. Validate staging contents
/// 6. `SessionManager.pauseForRestore()`
/// 7. Stage aside XMTP files + snapshot identity (rollback anchors)
/// 8. `DatabaseManager.replaceDatabase`
/// 9. Throwaway Client.build → importArchive → dropLocalDatabaseConnection
/// 10. Commit boundary — past here, errors are non-fatal
/// 11. markAllConversationsInactive
/// 12. `XMTPInstallationRevoker.revokeOtherInstallations` (non-fatal)
/// 13. `SessionManager.resumeAfterRestore()`
///
/// Rollback path (pre-commit): restore XMTP file stash, restore
/// keychain snapshot, resumeAfterRestore. Post-commit failures are
/// surfaced but do not roll back — GRDB + keychain are already in
/// the restored state.
public actor RestoreManager {
    public typealias ThrowawayClientBuilder = @Sendable (
        _ identity: KeychainIdentity,
        _ environment: AppEnvironment
    ) async throws -> any XMTPClientProvider

    // MARK: - Dependencies

    private let databaseManager: any DatabaseManagerProtocol
    private let identityStore: any KeychainIdentityStoreProtocol
    private let sessionManager: SessionManager
    private let environment: AppEnvironment
    private let clientBuilder: ThrowawayClientBuilder
    private let currentSchemaGeneration: String
    private let identityPollInterval: Duration
    private let identityTimeout: Duration

    public private(set) var state: RestoreState = .idle

    public init(
        databaseManager: any DatabaseManagerProtocol,
        identityStore: any KeychainIdentityStoreProtocol,
        sessionManager: SessionManager,
        environment: AppEnvironment,
        clientBuilder: @escaping ThrowawayClientBuilder = RestoreManager.productionClientBuilder,
        currentSchemaGeneration: String,
        identityPollInterval: Duration = .milliseconds(500),
        identityTimeout: Duration = .seconds(30)
    ) {
        self.databaseManager = databaseManager
        self.identityStore = identityStore
        self.sessionManager = sessionManager
        self.environment = environment
        self.clientBuilder = clientBuilder
        self.currentSchemaGeneration = currentSchemaGeneration
        self.identityPollInterval = identityPollInterval
        self.identityTimeout = identityTimeout
    }

    // MARK: - Discovery

    /// Look for an available backup bundle near the current device's
    /// iCloud container or local fallback. Reads the **sidecar** only
    /// — no decryption — so discovery works before the identity has
    /// arrived via iCloud Keychain.
    public nonisolated static func findAvailableBackup(
        environment: AppEnvironment
    ) -> (url: URL, sidecar: BackupBundleMetadata.Sidecar)? {
        let fm = FileManager.default
        let deviceId = DeviceInfo.deviceIdentifier

        let candidates: [URL] = [
            fm.url(forUbiquityContainerIdentifier: environment.iCloudContainerIdentifier)?
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true)
                .appendingPathComponent(deviceId, isDirectory: true),
            environment.defaultDatabasesDirectoryURL
                .appendingPathComponent("backups", isDirectory: true)
                .appendingPathComponent(deviceId, isDirectory: true),
        ].compactMap { $0 }

        for dir in candidates {
            guard BackupBundleMetadata.exists(in: dir) else { continue }
            guard let sidecar = try? BackupBundleMetadata.readSidecar(from: dir) else { continue }

            let bundle = dir.appendingPathComponent("backup-latest.encrypted")
            guard fm.fileExists(atPath: bundle.path) else { continue }

            // schemaGeneration-mismatch rejection belongs to the restore
            // path (so we can surface a specific error); discovery
            // returns the sidecar so the UI can format the
            // mismatch message.
            return (bundle, sidecar)
        }
        return nil
    }

    // MARK: - Main flow

    public func restoreFromBackup(bundleURL: URL) async throws {
        state = .decrypting

        let bundleData = try readBundle(at: bundleURL)
        let staging = try BackupBundle.createStagingDirectory()
        var cleanStaging = true
        defer {
            if cleanStaging {
                BackupBundle.cleanup(directory: staging)
            }
        }

        let identity = try await awaitIdentity()

        do {
            try BackupBundle.unpack(
                data: bundleData,
                encryptionKey: identity.keys.databaseKey,
                to: staging
            )
        } catch {
            throw RestoreError.decryptionFailed(error)
        }

        state = .validating
        let fullMetadata = try readAndValidateMetadata(stagingDir: staging)

        state = .preparingSession
        do {
            try await sessionManager.pauseForRestore()
        } catch {
            throw RestoreError.sessionPauseFailed(error)
        }

        var committed = false

        // Stash existing XMTP files before the swap so a rollback can
        // restore them. Keychain doesn't need separate snapshotting
        // here — the identity itself is unchanged across a restore,
        // only GRDB + xmtp-*.db3 get replaced.
        let xmtpStashDir: URL?
        do {
            xmtpStashDir = try stageXMTPFiles()
        } catch {
            await sessionManager.resumeAfterRestore()
            throw RestoreError.replaceFailed(error)
        }

        do {
            try await performRestore(
                identity: identity,
                stagingDir: staging,
                fullMetadata: fullMetadata
            )
            committed = true
        } catch {
            // Pre-commit failure: restore the stash, then rethrow.
            if let stash = xmtpStashDir {
                restoreXMTPStash(from: stash)
            }
            await sessionManager.resumeAfterRestore()
            state = .failed(error.localizedDescription)
            throw error
        }

        // Post-commit, stash is stale — throw it away.
        if let stash = xmtpStashDir {
            try? FileManager.default.removeItem(at: stash)
        }

        // Resume regardless of whether post-commit steps had issues.
        // Those are surfaced via `state` (archiveImportFailed,
        // revokeStale failure logs), not via throws.
        await sessionManager.resumeAfterRestore()

        if committed {
            if case .archiveImportFailed = state {
                // Leave the state as-is; completed doesn't apply.
            } else {
                state = .completed
            }
        }

        // cleanStaging stays true — the defer cleans up the staging dir.
        _ = cleanStaging
    }

    // MARK: - Step helpers

    private func readBundle(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw RestoreError.bundleUnreadable(error)
        }
    }

    private func awaitIdentity() async throws -> KeychainIdentity {
        let deadline = ContinuousClock.now.advanced(by: identityTimeout)
        while ContinuousClock.now < deadline {
            if let identity = try? identityStore.loadSync() {
                return identity
            }
            try await Task.sleep(for: identityPollInterval)
        }
        // One final attempt after deadline so a just-synced identity
        // isn't missed by a hair.
        if let identity = try? identityStore.loadSync() {
            return identity
        }
        throw RestoreError.identityTimeout
    }

    private func readAndValidateMetadata(stagingDir: URL) throws -> BackupBundleMetadata {
        let metadata: BackupBundleMetadata
        do {
            metadata = try BackupBundleMetadata.readFull(from: stagingDir)
        } catch {
            throw RestoreError.validationFailed("metadata.json unreadable: \(error.localizedDescription)")
        }

        guard metadata.schemaGeneration == currentSchemaGeneration else {
            QAEvent.emit(
                .conversation,
                "schema_generation_mismatch",
                [
                    "bundle": metadata.schemaGeneration,
                    "current": currentSchemaGeneration,
                ]
            )
            throw RestoreError.schemaGenerationMismatch(
                bundleGeneration: metadata.schemaGeneration,
                currentGeneration: currentSchemaGeneration
            )
        }

        let dbPath = BackupBundle.databasePath(in: stagingDir)
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            throw RestoreError.validationFailed("GRDB snapshot missing from bundle")
        }

        let archivePath = BackupBundle.xmtpArchivePath(in: stagingDir)
        guard FileManager.default.fileExists(atPath: archivePath.path) else {
            throw RestoreError.validationFailed("XMTP archive missing from bundle")
        }

        guard metadata.archiveKey.count == BackupBundleCrypto.expectedKeyLength else {
            throw RestoreError.validationFailed("archiveKey missing or wrong length")
        }

        return metadata
    }

    private func performRestore(
        identity: KeychainIdentity,
        stagingDir: URL,
        fullMetadata: BackupBundleMetadata
    ) async throws {
        state = .replacingDatabase
        let dbPath = BackupBundle.databasePath(in: stagingDir)
        do {
            try databaseManager.replaceDatabase(with: dbPath)
        } catch {
            throw RestoreError.replaceFailed(error)
        }

        state = .importingArchive
        var archiveImportError: (any Error)?
        do {
            try await importXMTPArchive(
                identity: identity,
                archivePath: BackupBundle.xmtpArchivePath(in: stagingDir).path,
                archiveKey: fullMetadata.archiveKey
            )
        } catch {
            // Non-fatal: GRDB is already restored, so the user ends
            // up with the conversation list but missing history.
            // CP3e will persist the archive bytes for retry.
            Log.warning("Archive import failed (non-fatal): \(error)")
            archiveImportError = error
        }

        do {
            let writer = ConversationLocalStateWriter(databaseWriter: databaseManager.dbWriter)
            try await writer.markAllConversationsInactive()
        } catch {
            Log.warning("markAllConversationsInactive failed (non-fatal): \(error)")
        }

        if archiveImportError == nil {
            state = .revokingStaleInstallations
        }
        await revokeStaleInstallations(identity: identity)

        // Re-pin the archive-import state as the final post-commit
        // signal so `completed` vs `archiveImportFailed` is stable
        // by the time the caller observes it.
        if let archiveImportError {
            state = .archiveImportFailed(archiveImportError.localizedDescription)
        }
    }

    private func importXMTPArchive(
        identity: KeychainIdentity,
        archivePath: String,
        archiveKey: Data
    ) async throws {
        let client = try await clientBuilder(identity, environment)
        defer { try? client.dropLocalDatabaseConnection() }
        try await client.importArchive(path: archivePath, encryptionKey: archiveKey)
    }

    private func revokeStaleInstallations(identity: KeychainIdentity) async {
        do {
            let client = try await clientBuilder(identity, environment)
            defer { try? client.dropLocalDatabaseConnection() }
            _ = try await XMTPInstallationRevoker.revokeOtherInstallations(
                client: client,
                signingKey: identity.keys.signingKey,
                keepInstallationId: client.installationId
            )
        } catch {
            Log.warning("revokeStaleInstallations failed (non-fatal): \(error)")
        }
    }

    // MARK: - Stash helpers

    private func stageXMTPFiles() throws -> URL? {
        let fm = FileManager.default
        let stashDir = fm.temporaryDirectory
            .appendingPathComponent("xmtp-restore-stash-\(UUID().uuidString)")
        try fm.createDirectory(at: stashDir, withIntermediateDirectories: true)

        let source = environment.defaultDatabasesDirectoryURL
        guard let files = try? fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return stashDir
        }

        for file in files where file.lastPathComponent.hasPrefix("xmtp-") &&
            !file.lastPathComponent.hasPrefix("xmtp-restore-stash-") {
            let destination = stashDir.appendingPathComponent(file.lastPathComponent)
            try? fm.moveItem(at: file, to: destination)
        }
        return stashDir
    }

    private func restoreXMTPStash(from stashDir: URL) {
        let fm = FileManager.default
        let dest = environment.defaultDatabasesDirectoryURL
        guard let files = try? fm.contentsOfDirectory(
            at: stashDir,
            includingPropertiesForKeys: nil
        ) else {
            try? fm.removeItem(at: stashDir)
            return
        }
        for file in files {
            let target = dest.appendingPathComponent(file.lastPathComponent)
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: file, to: target)
        }
        try? fm.removeItem(at: stashDir)
    }

    // MARK: - Production client builder

    /// Default throwaway-client factory for production. Builds an
    /// `XMTPiOS.Client` against the (now-empty) XMTP DB directory on
    /// the restored identity. The caller `defer`s
    /// `dropLocalDatabaseConnection` so the pool releases before
    /// `resumeAfterRestore` rebuilds the real session client.
    public static let productionClientBuilder: ThrowawayClientBuilder = { identity, environment in
        let api = XMTPAPIOptionsBuilder.build(environment: environment)
        let options = ClientOptions(
            api: api,
            dbEncryptionKey: identity.keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory
        )
        return try await Client.build(
            publicIdentity: identity.keys.signingKey.identity,
            options: options,
            inboxId: identity.inboxId
        )
    }
}
