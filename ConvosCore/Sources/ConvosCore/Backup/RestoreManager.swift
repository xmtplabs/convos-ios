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

/// Pair of the discovery sidecar + the resolved bundle URL so callers
/// can flow straight from `findAvailableBackup` into
/// `restoreFromBackup(bundleURL:)` without re-resolving directories.
public struct AvailableBackup: Sendable, Equatable {
    public let sidecar: BackupSidecarMetadata
    public let bundleURL: URL

    public init(sidecar: BackupSidecarMetadata, bundleURL: URL) {
        self.sidecar = sidecar
        self.bundleURL = bundleURL
    }
}

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
    public func findAvailableBackup() -> AvailableBackup? {
        findAvailableBackups().first
    }

    /// Enumerates all compatible backups, sorted newest first. If two sidecars
    /// have identical creation dates, sort by bundle modification date and then
    /// stable device metadata so restore selection is deterministic.
    public func findAvailableBackups() -> [AvailableBackup] {
        let directories = backupRootDirectories()
        // Kick downloads of any iCloud placeholders before enumerating so
        // a backup written from another device becomes visible on the
        // next refresh tick. See `requestICloudDownloadsIfNeeded` for
        // the full rationale.
        requestICloudDownloadsIfNeeded(in: directories)

        var backups: [AvailableBackup] = []
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
                guard LegacyDataWipe.isCompatibleGeneration(sidecar.schemaGeneration) else {
                    Log.info("RestoreManager: skipping bundle with incompatible schema " +
                        "(\(sidecar.schemaGeneration) vs \(LegacyDataWipe.currentGeneration))")
                    continue
                }
                let bundleURL = dir.appendingPathComponent("backup-latest.encrypted")
                guard fileManager.fileExists(atPath: bundleURL.path) else {
                    continue
                }
                backups.append(AvailableBackup(sidecar: sidecar, bundleURL: bundleURL))
            }
        }
        return backups.sorted { lhs, rhs in
            compare(lhs, rhs)
        }
    }

    /// iCloud Documents items written by another device are not downloaded
    /// to this device automatically. They appear in the directory as
    /// hidden `.<name>.icloud` placeholders, so the standard listing
    /// (with `.skipsHiddenFiles`) returns an empty subdirectory and
    /// `findAvailableBackups` silently misses the new bundle. Walk the
    /// roots one level deep (roots → device-id subdirectories → sidecar
    /// + bundle), spot the placeholders, and ask iOS to download them.
    /// The call is non-blocking; downloads usually complete within
    /// seconds and the next refresh tick will see the real files.
    private func requestICloudDownloadsIfNeeded(in roots: [URL]) {
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }
            for entry in entries {
                queueDownloadIfPlaceholder(entry)
                guard isDirectory(entry) else { continue }
                if let children = try? fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: []
                ) {
                    for child in children {
                        queueDownloadIfPlaceholder(child)
                    }
                }
            }
        }
    }

    private func queueDownloadIfPlaceholder(_ url: URL) {
        let name = url.lastPathComponent
        let suffix = ".icloud"
        guard name.hasPrefix("."), name.hasSuffix(suffix) else { return }
        let realName = String(name.dropFirst().dropLast(suffix.count))
        let realURL = url.deletingLastPathComponent().appendingPathComponent(realName)
        do {
            try fileManager.startDownloadingUbiquitousItem(at: realURL)
            Log.info("RestoreManager: requested iCloud download for \(realName)")
        } catch {
            Log.warning("RestoreManager: failed to start iCloud download for \(realName): \(error)")
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Runs the full restore pipeline against `bundleURL`. See
    /// `docs/plans/icloud-backup-single-inbox.md` — "Restore flow (new)"
    /// for the step-by-step contract.
    public func restoreFromBackup(bundleURL: URL) async throws {
        guard !RestoreInProgressFlag.isSet(defaults: restoreFlagDefaults) else {
            throw RestoreError.restoreAlreadyInProgress
        }

        state = .decrypting

        // Pre-transaction phase under the two-key model:
        // 1. Wait for the synced backup key (the bundle is sealed with
        //    it). The destination device may not have any local
        //    identity yet — that's the whole point of the new model;
        //    identity comes FROM the bundle, not before.
        // 2. Stage + unseal the bundle.
        // 3. Adopt the bundled identity to the local (per-device,
        //    non-synced) slot. After this point the rest of the flow
        //    sees a populated `identityStore.loadSync()`.
        // Each step can throw — wrap so observable `state` reflects
        // `.failed` instead of being stuck at `.decrypting`. Split into
        // separate do-catches so the staging-dir cleanup `defer` is
        // registered immediately after the dir is created and fires
        // even if subsequent steps throw.
        let backupKey: Data
        do {
            backupKey = try await awaitBackupKeyWithTimeout()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }

        let stagingDir: URL
        do {
            stagingDir = try BackupBundle.createStagingDirectory()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
        defer { BackupBundle.cleanup(directory: stagingDir) }

        let innerMetadata: BackupBundleMetadata
        do {
            innerMetadata = try decryptAndValidateBundle(
                bundleURL: bundleURL,
                backupKey: backupKey,
                stagingDir: stagingDir
            )
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }

        // Capture the prior identity (if any) so every throw past the
        // adoption point can revert the keychain. Without this, a
        // failure between adopt and successful commit leaves the device
        // with the bundle's identity but the device's previous DB
        // files — encrypted under a different `databaseKey` — which
        // makes the next launch unable to open XMTP.
        let prevIdentity: KeychainIdentity?
        do {
            prevIdentity = try await identityStore.load()
        } catch {
            Log.warning("RestoreManager: could not read prior identity for rollback snapshot: \(error)")
            prevIdentity = nil
        }

        // Adopt the bundled identity into this device's local slot.
        // After this point the runtime store's `loadSync()` returns the
        // adopted identity — the rest of restore (Client.create with
        // `signingKey`, archive import, revocation) flows from here.
        let identity: KeychainIdentity
        do {
            identity = try await adoptIdentityFromBundle(innerMetadata)
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }

        // Begin transaction. Pre-commit artifacts live in the shared container
        // so crash recovery on next launch can find them. Setup itself is
        // wrapped — a failure to create the transaction directory would
        // otherwise leave RestoreInProgressFlag and RestoreTransactionStore
        // set forever, locking the NSE out and making every later restore
        // throw `.restoreAlreadyInProgress` until the user reinstalls.
        var transaction = RestoreTransaction(phase: .paused)
        let transactionDir = RestoreArtifactLayout.transactionDirectory(
            for: transaction.id,
            environment: environment
        )
        do {
            RestoreTransactionStore.save(transaction, defaults: restoreFlagDefaults)
            RestoreInProgressFlag.set(true, defaults: restoreFlagDefaults)
            try fileManager.createDirectory(at: transactionDir, withIntermediateDirectories: true)
        } catch {
            RestoreTransactionStore.clear(defaults: restoreFlagDefaults)
            RestoreInProgressFlag.set(false, defaults: restoreFlagDefaults)
            await restoreIdentitySnapshot(prevIdentity)
            state = .failed(error.localizedDescription)
            throw error
        }

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
            // GRDB restore is still the primary contract. Once a throwaway
            // installation has been created, keep it even if the archive bytes
            // fail to import so the revocation pass can still retire the old
            // devices without orphaning this one.
            state = .importingArchive
            let archivePath = BackupBundle.archivePath(in: stagingDir)
            let archiveImportResult = await importArchiveNonFatally(
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

            // Revocation of other installations. Non-fatal on failure —
            // the restore has already committed the GRDB + archive state,
            // and a retry from settings will clean up any stragglers.
            // Skipped only if installation creation failed before we had a
            // keeper id. Archive import itself is allowed to fail after that;
            // the new installation is still valid and should become the only
            // surviving one.
            if let revoker = installationRevoker,
               let keepInstallationId = archiveImportResult?.installationId {
                do {
                    _ = try await revoker(
                        identity.inboxId,
                        identity.keys.signingKey,
                        keepInstallationId
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
            await restoreIdentitySnapshot(prevIdentity)
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Re-applies the identity that was in the local keychain slot
    /// before `adoptIdentityFromBundle` overwrote it. Called from every
    /// rollback path past the adoption point so a failed restore leaves
    /// this device's keychain consistent with its (rolled-back) GRDB
    /// and XMTP files.
    ///
    /// Caveat: in-memory only. Crash recovery (which calls
    /// `rollbackTransaction` from a fresh process via
    /// `RestoreRecoveryManager`) does not have the prior snapshot in
    /// scope — that gap is documented in
    /// `docs/plans/single-inbox-two-key-model.md`. The common case
    /// (in-process throw) is covered.
    private func restoreIdentitySnapshot(_ snapshot: KeychainIdentity?) async {
        do {
            if let snapshot {
                _ = try await identityStore.save(
                    inboxId: snapshot.inboxId,
                    clientId: snapshot.clientId,
                    keys: snapshot.keys
                )
                Log.info("RestoreManager: restored prior identity to local keychain slot")
            } else {
                try await identityStore.delete()
                Log.info("RestoreManager: cleared adopted identity (no prior identity to restore)")
            }
        } catch {
            Log.error("RestoreManager: identity snapshot restore failed: \(error)")
        }
    }

    // MARK: - Decrypt + validate

    private func decryptAndValidateBundle(
        bundleURL: URL,
        backupKey: Data,
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
                encryptionKey: backupKey,
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
        guard LegacyDataWipe.isCompatibleGeneration(metadata.schemaGeneration) else {
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

    // MARK: - Backup-key gate (two-key model)

    /// Bounded poll on the synced backup-key slot. iCloud Keychain may
    /// still be delivering it at launch on a fresh paired device — the
    /// bundle is unsealed with this key, not with any per-device
    /// identity (which under the two-key model comes FROM the bundle).
    private func awaitBackupKeyWithTimeout(
        timeout: Duration = .seconds(30)
    ) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            do {
                if let key = try await identityStore.loadBackupKeySync() {
                    return key
                }
            } catch let error as KeychainIdentityStoreError {
                if case .identityNotFound = error {
                    // keep polling
                } else {
                    Log.error("RestoreManager: keychain read failed during backup-key wait: \(error)")
                    throw error
                }
            } catch {
                Log.error("RestoreManager: unexpected error during backup-key wait: \(error)")
                throw error
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RestoreError.backupKeyNotAvailable
    }

    /// Adopts the identity packaged inside `innerMetadata` into this
    /// device's per-device (non-synced) identity slot. Required for the
    /// rest of the restore flow (`Client.create`, archive import,
    /// installation revocation) to operate against the inbox the bundle
    /// belongs to.
    private func adoptIdentityFromBundle(_ innerMetadata: BackupBundleMetadata) async throws -> KeychainIdentity {
        guard let payload = innerMetadata.identityPayload else {
            // Pre-two-key bundle. We have no way to recover the identity
            // and can't proceed safely.
            throw RestoreError.bundleCorrupt(
                "legacy bundle has no identity payload — cannot adopt identity under the two-key model"
            )
        }
        let identity: KeychainIdentity
        do {
            identity = try JSONDecoder().decode(KeychainIdentity.self, from: payload)
        } catch {
            throw RestoreError.bundleCorrupt("identity payload could not be decoded: \(error.localizedDescription)")
        }
        do {
            _ = try await identityStore.save(
                inboxId: identity.inboxId,
                clientId: identity.clientId,
                keys: identity.keys
            )
        } catch {
            throw RestoreError.replaceDatabaseFailed(
                "could not write adopted identity to local keychain slot: \(error.localizedDescription)"
            )
        }
        Log.info("RestoreManager: adopted bundled identity for inboxId=\(identity.inboxId)")
        return identity
    }

    // MARK: - Identity gate (legacy — pre-two-key)

    /// Bounded poll on `identityStore.loadSync`. iCloud Keychain may still be
    /// syncing at launch; minting a new identity now would make the bundle
    /// permanently undecryptable.
    @available(*, deprecated, message: "Two-key model uses awaitBackupKeyWithTimeout. Kept for binary compat during transition.")
    private func awaitIdentityWithTimeout(
        timeout: Duration = .seconds(30)
    ) async throws -> KeychainIdentity {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            do {
                if let identity = try identityStore.loadSync() {
                    return identity
                }
            } catch let error as KeychainIdentityStoreError {
                // `identityNotFound` is the "iCloud Keychain hasn't
                // synced yet" case — keep polling. Anything else is a
                // hard keychain failure (corrupt payload, access
                // denied, locked daemon, etc.) and propagating it now
                // is more useful than waiting out the 30s and
                // reporting a misleading `identityNotAvailable`.
                if case .identityNotFound = error {
                    // keep polling
                } else {
                    Log.error("RestoreManager: keychain read failed during identity wait: \(error)")
                    throw error
                }
            } catch {
                Log.error("RestoreManager: unexpected error during identity wait: \(error)")
                throw error
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
                throw RestoreError.replaceDatabaseFailed(
                    "failed to stash XMTP file \(entry.lastPathComponent): \(error.localizedDescription)"
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

    /// Returns the throwaway import result when installation creation reached
    /// the point where there is a keeper id. If client creation itself fails,
    /// returns `nil` and the caller skips revocation to avoid orphaning this
    /// device.
    private func importArchiveNonFatally(
        archivePath: URL,
        archiveKey: Data,
        identity: KeychainIdentity
    ) async -> RestoreArchiveImportResult? {
        do {
            let result = try await archiveImporter.importArchive(
                at: archivePath,
                encryptionKey: archiveKey,
                identity: identity
            )
            if let reason = result.archiveImportFailureReason {
                persistArchiveImportFailure(reason: reason)
            }
            return result
        } catch {
            Log.error("RestoreManager: archive importer failed before creating an installation: \(error)")
            persistArchiveImportFailure(reason: error.localizedDescription)
            return nil
        }
    }

    private func persistArchiveImportFailure(reason: String) {
        let failure = PendingArchiveImportFailure(reason: reason)
        PendingArchiveImportFailureStorage.save(failure, defaults: restoreFlagDefaults)
        state = .archiveImportFailed(reason: reason)
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

    private func compare(_ lhs: AvailableBackup, _ rhs: AvailableBackup) -> Bool {
        if lhs.sidecar.createdAt != rhs.sidecar.createdAt {
            return lhs.sidecar.createdAt > rhs.sidecar.createdAt
        }
        let lhsModifiedAt = modificationDate(for: lhs.bundleURL) ?? .distantPast
        let rhsModifiedAt = modificationDate(for: rhs.bundleURL) ?? .distantPast
        if lhsModifiedAt != rhsModifiedAt {
            return lhsModifiedAt > rhsModifiedAt
        }
        let nameComparison = lhs.sidecar.deviceName.localizedStandardCompare(rhs.sidecar.deviceName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return lhs.sidecar.deviceId < rhs.sidecar.deviceId
    }

    private func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

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
