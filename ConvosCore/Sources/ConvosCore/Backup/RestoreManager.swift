import Foundation
import GRDB
@preconcurrency import XMTPiOS

/// Closure the restore flow calls to pause / resume the session around the
/// destructive swap. The real caller (lands in chunk 3c.4) wires this to
/// `SessionManager.pauseForRestore()` / `resumeAfterRestore()`. Optional so
/// tests can bypass it.
public protocol RestoreLifecycleControlling: Sendable {
    func pauseForRestore() async
    func resumeAfterRestore() async
}

/// Optional installation-revocation hook used at the tail of the restore.
/// Signature matches `XMTPInstallationRevoker.revokeOtherInstallations` —
/// returning the count revoked. Non-fatal on the call site. `nil` skips.
public typealias RestoreInstallationRevoker = @Sendable (
    _ inboxId: String,
    _ signingKey: any SigningKey,
    _ keepInstallationId: String?
) async throws -> Int

public actor RestoreManager {
    private let identityStore: any KeychainIdentityStoreProtocol
    private let databaseManager: any DatabaseManagerProtocol
    private let archiveImporter: any RestoreArchiveImporting
    private let lifecycleController: (any RestoreLifecycleControlling)?
    private let installationRevoker: RestoreInstallationRevoker?
    private let environment: AppEnvironment
    private let restoreFlagDefaults: UserDefaults
    private let fileManager: FileManager

    public private(set) var state: RestoreState = .idle

    public init(
        identityStore: any KeychainIdentityStoreProtocol,
        databaseManager: any DatabaseManagerProtocol,
        archiveImporter: any RestoreArchiveImporting,
        lifecycleController: (any RestoreLifecycleControlling)? = nil,
        installationRevoker: RestoreInstallationRevoker? = nil,
        environment: AppEnvironment,
        restoreFlagSuiteName: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.identityStore = identityStore
        self.databaseManager = databaseManager
        self.archiveImporter = archiveImporter
        self.lifecycleController = lifecycleController
        self.installationRevoker = installationRevoker
        self.environment = environment
        let suite = restoreFlagSuiteName ?? environment.appGroupIdentifier
        self.restoreFlagDefaults = UserDefaults(suiteName: suite) ?? .standard
        self.fileManager = fileManager
    }

    // MARK: - Public API

    /// Enumerates backup directories visible to this install and returns the
    /// newest compatible sidecar. Bundles whose `schemaGeneration` no longer
    /// matches the running app are rejected — they'd be wiped by
    /// `LegacyDataWipe` at next launch anyway, so surfacing them as
    /// restorable would be misleading.
    public func findAvailableBackup() -> BackupSidecarMetadata? {
        let directories = backupRootDirectories()
        var newest: BackupSidecarMetadata?
        for root in directories {
            guard let subdirs = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for dir in subdirs {
                guard BackupSidecarMetadata.exists(in: dir),
                      let sidecar = try? BackupSidecarMetadata.read(from: dir) else {
                    continue
                }
                guard sidecar.schemaGeneration == LegacyDataWipe.currentGeneration else {
                    Log.info("RestoreManager: skipping bundle with incompatible schema " +
                        "(\(sidecar.schemaGeneration) vs \(LegacyDataWipe.currentGeneration))")
                    continue
                }
                if let current = newest {
                    if sidecar.createdAt > current.createdAt {
                        newest = sidecar
                    }
                } else {
                    newest = sidecar
                }
            }
        }
        return newest
    }

    /// Runs the full restore pipeline against `bundleURL`. See
    /// `docs/plans/icloud-backup-single-inbox.md` — "Restore flow (new)"
    /// for the step-by-step contract.
    public func restoreFromBackup(bundleURL: URL) async throws {
        guard !RestoreInProgressFlag.isSet(defaults: restoreFlagDefaults) else {
            throw RestoreError.restoreAlreadyInProgress
        }

        state = .decrypting
        let identity = try await awaitIdentityWithTimeout()

        let stagingDir = try BackupBundle.createStagingDirectory()
        defer { BackupBundle.cleanup(directory: stagingDir) }

        let innerMetadata = try decryptAndValidateBundle(
            bundleURL: bundleURL,
            identity: identity,
            stagingDir: stagingDir
        )

        // Begin transaction. Pre-commit artifacts live in the shared container
        // so crash recovery on next launch can find them.
        var transaction = RestoreTransaction(phase: .paused)
        RestoreTransactionStore.save(transaction, defaults: restoreFlagDefaults)
        RestoreInProgressFlag.set(true, defaults: restoreFlagDefaults)
        let transactionDir = RestoreArtifactLayout.transactionDirectory(
            for: transaction.id,
            environment: environment
        )
        try fileManager.createDirectory(at: transactionDir, withIntermediateDirectories: true)

        // Defer-based rollback is inadequate here because we need async calls;
        // wrap the critical section in do-catch with explicit rollback.
        do {
            await lifecycleController?.pauseForRestore()

            // Stash existing XMTP DB files aside so the throwaway client opens
            // an empty DB (required for Client.build by inboxId).
            let stashDir = RestoreArtifactLayout.xmtpStashDirectory(
                for: transaction.id,
                environment: environment
            )
            try stageXMTPFiles(to: stashDir)

            // GRDB rollback snapshot — written to the shared container via
            // databaseReader.backup so crash recovery can pick it up.
            let snapshotURL = RestoreArtifactLayout.grdbSnapshotURL(
                for: transaction.id,
                environment: environment
            )
            try fileManager.createDirectory(
                at: snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try takeGRDBSnapshot(to: snapshotURL)

            state = .replacingDatabase
            let dbPath = BackupBundle.databasePath(in: stagingDir)
            do {
                try databaseManager.replaceDatabase(with: dbPath)
            } catch {
                throw RestoreError.replaceDatabaseFailed(error.localizedDescription)
            }

            transaction.phase = .databaseReplaced
            RestoreTransactionStore.save(transaction, defaults: restoreFlagDefaults)

            // Archive import — non-fatal per the plan. Failure surfaces as
            // `RestoreState.archiveImportFailed` + a persisted summary; the
            // GRDB restore is still the primary contract.
            state = .importingArchive
            let archivePath = BackupBundle.archivePath(in: stagingDir)
            await importArchiveNonFatally(
                archivePath: archivePath,
                archiveKey: innerMetadata.archiveKey,
                identity: identity
            )

            // Redundant with the XMTP archive's own semantics (imported
            // conversations are inactive by default) but covers conversations
            // present in GRDB but absent from the archive.
            try? await ConversationLocalStateWriter(
                databaseWriter: databaseManager.dbWriter
            ).markAllConversationsInactive()

            // Non-fatal revocation of other installations.
            if let revoker = installationRevoker {
                do {
                    _ = try await revoker(
                        identity.inboxId,
                        identity.keys.signingKey,
                        identity.clientId
                    )
                } catch {
                    Log.warning("RestoreManager: installation revocation failed: \(error)")
                }
            }

            // Commit. Past this point we do not roll back.
            transaction.phase = .committed
            RestoreTransactionStore.save(transaction, defaults: restoreFlagDefaults)

            await lifecycleController?.resumeAfterRestore()

            cleanupTransaction(id: transaction.id)
            RestoreTransactionStore.clear(defaults: restoreFlagDefaults)
            RestoreInProgressFlag.set(false, defaults: restoreFlagDefaults)

            // Preserve `archiveImportFailed` if it was set — the caller's
            // observer needs to see the partial-success outcome.
            if case .archiveImportFailed = state {
                Log.info("RestoreManager: completed with archive import failure")
            } else {
                state = .completed
            }
        } catch {
            await rollbackTransaction(transaction: transaction, reason: error)
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Decrypt + validate

    private func decryptAndValidateBundle(
        bundleURL: URL,
        identity: KeychainIdentity,
        stagingDir: URL
    ) throws -> BackupBundleMetadata {
        let bundleData: Data
        do {
            bundleData = try Data(contentsOf: bundleURL)
        } catch {
            throw RestoreError.bundleCorrupt("could not read bundle: \(error.localizedDescription)")
        }

        do {
            try BackupBundle.unpack(
                data: bundleData,
                encryptionKey: identity.keys.databaseKey,
                to: stagingDir
            )
        } catch let error as BackupBundleCrypto.CryptoError {
            throw RestoreError.decryptionFailed(error.localizedDescription)
        } catch {
            throw RestoreError.bundleCorrupt(error.localizedDescription)
        }

        let metadata: BackupBundleMetadata
        do {
            metadata = try BackupBundleMetadata.read(from: stagingDir)
        } catch {
            throw RestoreError.bundleCorrupt("missing inner metadata: \(error.localizedDescription)")
        }

        let currentGeneration = LegacyDataWipe.currentGeneration
        guard metadata.schemaGeneration == currentGeneration else {
            QAEvent.emit(
                .backup,
                "schema_generation_mismatch",
                [
                    "bundle": metadata.schemaGeneration,
                    "current": currentGeneration,
                ]
            )
            throw RestoreError.schemaGenerationMismatch(
                bundleGeneration: metadata.schemaGeneration,
                currentGeneration: currentGeneration
            )
        }

        let dbPath = BackupBundle.databasePath(in: stagingDir)
        guard fileManager.fileExists(atPath: dbPath.path) else {
            throw RestoreError.missingComponent("convos-single-inbox.sqlite")
        }
        let archivePath = BackupBundle.archivePath(in: stagingDir)
        guard fileManager.fileExists(atPath: archivePath.path) else {
            throw RestoreError.missingComponent("xmtp-archive.bin")
        }

        return metadata
    }

    // MARK: - Identity gate

    /// Bounded poll on `identityStore.loadSync`. iCloud Keychain may still be
    /// syncing at launch; minting a new identity now would make the bundle
    /// permanently undecryptable.
    private func awaitIdentityWithTimeout(
        timeout: Duration = .seconds(30)
    ) async throws -> KeychainIdentity {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let identity = try? identityStore.loadSync() {
                return identity
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RestoreError.identityNotAvailable
    }

    // MARK: - XMTP stash

    private func stageXMTPFiles(to stashDir: URL) throws {
        try fileManager.createDirectory(at: stashDir, withIntermediateDirectories: true)
        let sourceDir = environment.defaultDatabasesDirectoryURL
        guard let entries = try? fileManager.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries where entry.lastPathComponent.hasPrefix("xmtp-") {
            let destination = stashDir.appendingPathComponent(entry.lastPathComponent)
            do {
                try fileManager.moveItem(at: entry, to: destination)
            } catch {
                Log.warning(
                    "RestoreManager: failed to stash XMTP file "
                    + "\(entry.lastPathComponent): \(error)"
                )
            }
        }
    }

    private func restoreStashedXMTPFiles(from stashDir: URL) {
        let destinationDir = environment.defaultDatabasesDirectoryURL
        guard let files = try? fileManager.contentsOfDirectory(
            at: stashDir,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files {
            let destination = destinationDir.appendingPathComponent(file.lastPathComponent)
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.moveItem(at: file, to: destination)
            } catch {
                Log.warning(
                    "RestoreManager: failed to restore stashed XMTP file "
                    + "\(file.lastPathComponent): \(error)"
                )
            }
        }
    }

    // MARK: - GRDB snapshot

    private func takeGRDBSnapshot(to url: URL) throws {
        try? fileManager.removeItem(at: url)
        let destination = try DatabaseQueue(path: url.path)
        try databaseManager.dbReader.backup(to: destination)
    }

    // MARK: - Archive import

    private func importArchiveNonFatally(
        archivePath: URL,
        archiveKey: Data,
        identity: KeychainIdentity
    ) async {
        do {
            try await archiveImporter.importArchive(
                at: archivePath,
                encryptionKey: archiveKey,
                identity: identity
            )
        } catch {
            Log.error("RestoreManager: archive import failed: \(error)")
            let failure = PendingArchiveImportFailure(reason: error.localizedDescription)
            PendingArchiveImportFailureStorage.save(failure, defaults: restoreFlagDefaults)
            state = .archiveImportFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Rollback + cleanup

    private func rollbackTransaction(transaction: RestoreTransaction, reason: any Error) async {
        Log.warning("RestoreManager: rolling back transaction \(transaction.id) — \(reason)")

        if transaction.phase == .databaseReplaced {
            let snapshotURL = RestoreArtifactLayout.grdbSnapshotURL(
                for: transaction.id,
                environment: environment
            )
            if fileManager.fileExists(atPath: snapshotURL.path) {
                do {
                    try databaseManager.replaceDatabase(with: snapshotURL)
                } catch {
                    Log.error("RestoreManager: rollback replaceDatabase failed: \(error)")
                }
            }
        }

        let stashDir = RestoreArtifactLayout.xmtpStashDirectory(
            for: transaction.id,
            environment: environment
        )
        if fileManager.fileExists(atPath: stashDir.path) {
            restoreStashedXMTPFiles(from: stashDir)
        }

        cleanupTransaction(id: transaction.id)
        RestoreTransactionStore.clear(defaults: restoreFlagDefaults)
        RestoreInProgressFlag.set(false, defaults: restoreFlagDefaults)

        // Resume the session — the caller still needs a working app.
        await lifecycleController?.resumeAfterRestore()
    }

    private func cleanupTransaction(id: UUID) {
        let dir = RestoreArtifactLayout.transactionDirectory(for: id, environment: environment)
        try? fileManager.removeItem(at: dir)
    }

    // MARK: - Discovery roots

    private func backupRootDirectories() -> [URL] {
        var roots: [URL] = []
        if let containerId = environment.iCloudContainerIdentifier,
           let containerURL = fileManager.url(forUbiquityContainerIdentifier: containerId) {
            roots.append(
                containerURL
                    .appendingPathComponent("Documents", isDirectory: true)
                    .appendingPathComponent("backups", isDirectory: true)
            )
        }
        roots.append(
            environment.defaultDatabasesDirectoryURL
                .appendingPathComponent("backups", isDirectory: true)
        )
        return roots
    }
}
