import Combine
import ConvosAppData
import ConvosInvites
import Foundation
import GRDB
import os
@preconcurrency import XMTPiOS

public struct VaultDevice: Sendable {
    public let inboxId: String
    public let name: String
    public let isCurrentDevice: Bool

    public init(inboxId: String, name: String, isCurrentDevice: Bool) {
        self.inboxId = inboxId
        self.name = name
        self.isCurrentDevice = isCurrentDevice
    }
}

public struct PairingJoinRequest: Sendable {
    public let pin: String
    public let deviceName: String
    public let joinerInboxId: String
}

public protocol VaultManagerDelegate: AnyObject, Sendable {
    func vaultManager(_ manager: VaultManager, didReceivePairingJoinRequest request: PairingJoinRequest)
    func vaultManager(_ manager: VaultManager, didReceivePinEcho pin: String, from joinerInboxId: String)
}

public enum VaultBootstrapState: Sendable, Equatable {
    case notStarted
    case ready
    case failed(String)
}

public actor VaultManager {
    let vaultClient: VaultClient
    let identityStore: any KeychainIdentityStoreProtocol
    let vaultKeyStore: VaultKeyStore?
    let databaseReader: any DatabaseReader
    var databaseWriter: (any DatabaseWriter)?
    let deviceName: String
    let keyCoordinator: VaultKeyCoordinator
    let deviceManager: VaultDeviceManager
    public private(set) var healthCheck: VaultHealthCheck?

    public weak var delegate: (any VaultManagerDelegate)?
    public weak var eventHandler: (any VaultEventHandler)?

    var dmStreamTask: Task<Void, Never>?
    var activePairingSlug: String?
    var joinerDmStreamTask: Task<Void, Never>?

    public private(set) var bootstrapState: VaultBootstrapState = .notStarted

    public var isConnected: Bool {
        get async { await vaultClient.isConnected }
    }

    public var hasMultipleDevices: Bool {
        let count = (try? VaultDeviceRepository(dbReader: databaseReader).count()) ?? 0
        return count > 1
    }

    public var vaultInboxId: String? {
        get async { await vaultClient.inboxId }
    }

    public init(
        identityStore: any KeychainIdentityStoreProtocol,
        vaultKeyStore: VaultKeyStore? = nil,
        databaseReader: any DatabaseReader,
        deviceName: String
    ) {
        let client = VaultClient()
        self.vaultClient = client
        self.identityStore = identityStore
        self.vaultKeyStore = vaultKeyStore
        self.databaseReader = databaseReader
        self.deviceName = deviceName
        self.keyCoordinator = VaultKeyCoordinator(
            vaultClient: client,
            identityStore: identityStore,
            databaseReader: databaseReader,
            deviceName: deviceName
        )
        self.deviceManager = VaultDeviceManager(
            vaultClient: client,
            databaseReader: databaseReader,
            deviceName: deviceName
        )
    }

    public func setDelegate(_ delegate: any VaultManagerDelegate) {
        self.delegate = delegate
    }

    public func setEventHandler(_ handler: any VaultEventHandler) {
        self.eventHandler = handler
        Task { await keyCoordinator.setEventHandler(handler) }
    }

    public func connect(signingKey: SigningKey, options: ClientOptions) async throws {
        await vaultClient.setDelegate(self)
        try await vaultClient.connect(signingKey: signingKey, options: options)
        await deviceManager.syncToDatabase()
    }

    public func bootstrapVault(
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment
    ) async {
        self.databaseWriter = databaseWriter
        await keyCoordinator.setDatabaseWriter(databaseWriter)
        await deviceManager.setDatabaseWriter(databaseWriter)

        guard let vaultKeyStore else {
            Log.warning("No VaultKeyStore configured, skipping vault bootstrap")
            return
        }

        do {
            Log.info("[Vault.bootstrap] starting, loading or creating vault identity")
            let identity = try await loadOrCreateVaultIdentity(vaultKeyStore: vaultKeyStore)
            Log.info("[Vault.bootstrap] identity loaded: inboxId=\(identity.inboxId) clientId=\(identity.clientId)")

            let signingKey = identity.keys.signingKey
            let api = XMTPAPIOptionsBuilder.build(environment: environment)
            let options = ClientOptions(
                api: api,
                codecs: [
                    ConversationDeletedCodec(),
                    DeviceKeyBundleCodec(),
                    DeviceKeyShareCodec(),
                    DeviceRemovedCodec(),
                    JoinRequestCodec(),
                    PairingMessageCodec(),
                    TextCodec(),
                ],
                dbEncryptionKey: identity.keys.databaseKey
            )

            Log.info("[Vault.bootstrap] connecting XMTP client for signing key identity=\(signingKey.identity.identifier)")
            try await connect(signingKey: signingKey, options: options)

            guard let inboxId = await vaultInboxId,
                  let installationId = await vaultClient.installationId else {
                throw VaultClientError.notConnected
            }

            Log.info("[Vault.bootstrap] XMTP client connected: inboxId=\(inboxId) installationId=\(installationId)")

            if identity.inboxId == "vault-pending" || identity.clientId != installationId {
                // Save the new/updated entry first, then delete the old one.
                // Add-first-then-delete preserves the existing key if the save
                // fails (e.g. keychain access denied), so the next bootstrap
                // still has something to load. A plain delete-then-save would
                // leave the vault permanently keyless on failure.
                let oldKey: String
                if identity.inboxId == "vault-pending" {
                    oldKey = "vault-pending"
                    Log.info("[Vault.bootstrap] persisting vault identity to keychain (was vault-pending, now inboxId=\(inboxId) clientId=\(installationId))")
                } else {
                    oldKey = identity.inboxId
                    Log.info("[Vault.bootstrap] updating vault keychain entry: inboxId=\(inboxId) oldClientId=\(identity.clientId) newClientId=\(installationId)")
                }

                do {
                    try await vaultKeyStore.save(
                        inboxId: inboxId,
                        clientId: installationId,
                        keys: identity.keys
                    )
                } catch {
                    Log.error("[Vault.bootstrap] failed to save updated vault keychain entry: \(error)")
                    throw error
                }

                // Only delete the old entry after the new one is confirmed in
                // the keychain. If the two entries share a key (same inboxId,
                // only clientId changed), save() will overwrite in place and
                // this delete is a no-op.
                if oldKey != inboxId {
                    do {
                        try await vaultKeyStore.delete(inboxId: oldKey)
                    } catch {
                        // Non-fatal: the new entry is saved, so the vault is
                        // recoverable on next bootstrap. Just leaves an orphan.
                        Log.warning("[Vault.bootstrap] failed to delete old vault keychain entry (\(oldKey)) after save — leaving orphan: \(error)")
                    }
                }
            } else {
                Log.info("[Vault.bootstrap] keychain identity already up-to-date (inboxId=\(inboxId))")
            }

            Log.info("[Vault.bootstrap] saving vault inbox row to GRDB: inboxId=\(inboxId) clientId=\(installationId)")
            let inboxWriter = InboxWriter(dbWriter: databaseWriter)
            try await inboxWriter.save(inboxId: inboxId, clientId: installationId, isVault: true)
            bootstrapState = .ready
            Log.info("[Vault.bootstrap] bootstrapped successfully: inboxId=\(inboxId)")

            // Diagnostic: log whether this vault installation is still active on the network.
            // If this returns false, it usually means another device restored from backup and
            // revoked this device's vault installation. The conversation-level stale detection
            // (InboxStateMachine) should handle the user-facing recovery — this log is just
            // for diagnosing rare partial-revocation states during QA.
            if let xmtpClient = await vaultClient.xmtpClient {
                do {
                    let state = try await xmtpClient.inboxState(refreshFromNetwork: true)
                    let isActive = state.installations.contains { $0.id == installationId }
                    if isActive {
                        Log.info("[Vault.bootstrap] vault installation is active on network ✓")
                    } else {
                        Log.warning("[Vault.bootstrap] vault installation NOT in active list — vault is stale (likely revoked by another device)")
                        QAEvent.emit(.vault, "stale_detected", ["inboxId": inboxId])
                    }
                } catch {
                    Log.debug("[Vault.bootstrap] inboxState check failed (non-fatal): \(error)")
                }
            }

            await keyCoordinator.startObservingInboxes()

            healthCheck = VaultHealthCheck(
                vaultClient: vaultClient,
                keyCoordinator: keyCoordinator,
                deviceManager: deviceManager,
                identityStore: identityStore,
                databaseReader: databaseReader,
                databaseWriter: databaseWriter
            )
        } catch {
            let message = "Failed to bootstrap vault: \(error)"
            bootstrapState = .failed(message)
            Log.error(message)
        }
    }

    private func loadOrCreateVaultIdentity(vaultKeyStore: VaultKeyStore) async throws -> KeychainIdentity {
        if let existing = try? await vaultKeyStore.loadAny() {
            Log.info("[Vault.loadOrCreateVaultIdentity] found existing vault identity: inboxId=\(existing.inboxId)")
            return existing
        }
        Log.info("[Vault.loadOrCreateVaultIdentity] no existing vault identity, generating fresh keys")
        let newKeys = try KeychainIdentityKeys.generate()
        let saved = try await vaultKeyStore.save(
            inboxId: "vault-pending",
            clientId: "vault-pending",
            keys: newKeys
        )
        Log.info("[Vault.loadOrCreateVaultIdentity] saved new vault-pending identity, awaiting inboxId from XMTP")
        return saved
    }

    // MARK: - Lifecycle

    public func disconnect() async {
        await vaultClient.disconnect()
    }

    /// Tears down the current vault and bootstraps a fresh one with new keys.
    ///
    /// Used after restore: the restored vault is inactive because the new
    /// installation was never added to the old vault's MLS group, and the vault
    /// is a single-user group with no third party to trigger re-addition.
    /// This method:
    ///   1. Disconnects the current vault client
    ///   2. Deletes the old vault key from local + iCloud keychain
    ///   3. Deletes the old DBInbox row for the vault
    ///   4. Re-runs `bootstrapVault()` which generates fresh keys and creates
    ///      a new vault (new inboxId, new MLS group)
    ///
    /// The old vault XMTP database file on disk is left as-is — it's no longer
    /// referenced by anything, but we don't touch it to avoid risk. A future
    /// cleanup pass can remove orphaned vault DB files.
    public func reCreate(
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment
    ) async throws {
        Log.info("[Vault.reCreate] === START ===")

        let oldInboxId = await vaultInboxId
        let oldInstallationId = await vaultClient.installationId
        let oldBootstrapState = stateDescription
        Log.info("[Vault.reCreate] before: inboxId=\(oldInboxId ?? "nil") installationId=\(oldInstallationId ?? "nil") state=\(oldBootstrapState)")

        if let vaultKeyStore {
            let beforeKeys = (try? await vaultKeyStore.loadAll()) ?? []
            Log.info("[Vault.reCreate] before: keychain has \(beforeKeys.count) vault key(s): \(beforeKeys.map(\.inboxId))")
        }

        let beforeInboxCount: Int
        do {
            beforeInboxCount = try await databaseWriter.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox WHERE isVault = 1") ?? 0
            }
            Log.info("[Vault.reCreate] before: GRDB has \(beforeInboxCount) vault inbox row(s)")
        } catch {
            Log.warning("[Vault.reCreate] failed to count vault inbox rows: \(error)")
        }

        Log.info("[Vault.reCreate] step 1/5: revoking other installations on old vault")
        if let oldInboxId, let vaultKeyStore {
            do {
                let identity = try await vaultKeyStore.load(inboxId: oldInboxId)
                try await revokeAllOtherInstallations(signingKey: identity.keys.signingKey)
                Log.info("[Vault.reCreate] step 1/5: revoked other installations on old vault inboxId=\(oldInboxId)")
            } catch {
                Log.warning("[Vault.reCreate] step 1/5: revocation failed (non-fatal): \(error)")
            }
        } else {
            Log.info("[Vault.reCreate] step 1/5: skipped — no old vault identity available")
        }

        Log.info("[Vault.reCreate] step 2/5: disconnecting current vault client")
        await vaultClient.disconnect()
        bootstrapState = .notStarted
        Log.info("[Vault.reCreate] step 2/5: disconnected, bootstrap state reset to notStarted")

        Log.info("[Vault.reCreate] step 3/5: deleting old vault key from keychain")
        if let vaultKeyStore, let oldInboxId {
            do {
                try await vaultKeyStore.delete(inboxId: oldInboxId)
                Log.info("[Vault.reCreate] step 3/5: deleted old vault key for inboxId=\(oldInboxId)")
            } catch {
                // Critical: if we can't delete the old key, the next bootstrap will pick it up
                // and we'll re-create with the same inboxId — which means no new vault.
                Log.error("[Vault.reCreate] step 3/5: failed to delete old vault key for \(oldInboxId): \(error)")
                throw VaultReCreateError.bootstrapFailed("failed to delete old vault key: \(error.localizedDescription)")
            }

            // Verify deletion and log any remaining keys
            let remainingKeys = (try? await vaultKeyStore.loadAll()) ?? []
            Log.info("[Vault.reCreate] step 3/5: keychain now has \(remainingKeys.count) vault key(s) remaining: \(remainingKeys.map(\.inboxId))")
        } else if let vaultKeyStore {
            // No known inboxId (e.g., disconnect failed before we captured it) — delete all
            Log.warning("[Vault.reCreate] step 3/5: no oldInboxId available, deleting all vault keys")
            do {
                try await vaultKeyStore.deleteAll()
            } catch {
                Log.error("[Vault.reCreate] step 3/5: failed to delete all vault keys: \(error)")
                throw VaultReCreateError.bootstrapFailed("failed to delete vault keys: \(error.localizedDescription)")
            }
            let remainingKeys = (try? await vaultKeyStore.loadAll()) ?? []
            Log.info("[Vault.reCreate] step 3/5: keychain now has \(remainingKeys.count) vault key(s) remaining")
        } else {
            Log.warning("[Vault.reCreate] step 3/5: no vaultKeyStore available, skipping keychain cleanup")
        }

        Log.info("[Vault.reCreate] step 4/5: deleting old vault inbox row from GRDB")
        do {
            try await databaseWriter.write { db in
                if let oldInboxId {
                    try db.execute(
                        sql: "DELETE FROM inbox WHERE inboxId = ? AND isVault = 1",
                        arguments: [oldInboxId]
                    )
                } else {
                    // No known inboxId — match the keychain cleanup behaviour and
                    // remove all vault inbox rows so the next bootstrap doesn't
                    // collide with an orphan via InboxWriterError.duplicateVault.
                    try db.execute(sql: "DELETE FROM inbox WHERE isVault = 1")
                }
            }
            Log.info("[Vault.reCreate] step 4/5: deleted old DBInbox row(s)")
        } catch {
            Log.error("[Vault.reCreate] step 4/5: failed to delete old DBInbox row(s): \(error)")
            throw VaultReCreateError.bootstrapFailed("failed to delete old vault inbox row(s): \(error.localizedDescription)")
        }

        let afterDeleteCount = (try? await databaseWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox WHERE isVault = 1") ?? 0
        }) ?? -1
        Log.info("[Vault.reCreate] step 4/5: GRDB now has \(afterDeleteCount) vault inbox row(s) remaining")

        Log.info("[Vault.reCreate] step 5/5: bootstrapping fresh vault (new keys, new identity)")
        await bootstrapVault(databaseWriter: databaseWriter, environment: environment)

        let afterBootstrapState = stateDescription
        Log.info("[Vault.reCreate] step 5/5: bootstrap finished with state=\(afterBootstrapState)")

        guard case .ready = bootstrapState else {
            Log.error("[Vault.reCreate] === FAILED === bootstrap did not reach ready state: \(afterBootstrapState)")
            throw VaultReCreateError.bootstrapFailed(afterBootstrapState)
        }

        let newInboxId = await vaultInboxId ?? "unknown"
        let newInstallationId = await vaultClient.installationId ?? "unknown"
        Log.info("[Vault.reCreate] after: inboxId=\(newInboxId) installationId=\(newInstallationId)")

        if let oldInboxId, oldInboxId == newInboxId {
            Log.error("[Vault.reCreate] new inboxId matches old inboxId — vault re-creation failed")
            throw VaultReCreateError.bootstrapFailed("new inboxId (\(newInboxId)) matches old inboxId — re-creation did not produce a fresh vault")
        }
        if let oldInboxId {
            Log.info("[Vault.reCreate] confirmed fresh vault: oldInboxId=\(oldInboxId) != newInboxId=\(newInboxId)")
        }

        if let vaultKeyStore {
            let afterKeys = (try? await vaultKeyStore.loadAll()) ?? []
            Log.info("[Vault.reCreate] after: keychain has \(afterKeys.count) vault key(s): \(afterKeys.map(\.inboxId))")
        }

        Log.info("[Vault.reCreate] === DONE ===")
    }

    private var stateDescription: String {
        switch bootstrapState {
        case .notStarted: return "notStarted"
        case .ready: return "ready"
        case .failed(let reason): return "failed(\(reason))"
        }
    }

    public var vaultInstallationId: String? {
        get async { await vaultClient.installationId }
    }

    public func revokeAllOtherInstallations(signingKey: any SigningKey) async throws {
        guard let client = await vaultClient.xmtpClient else {
            throw VaultClientError.notConnected
        }
        try await client.revokeAllOtherInstallations(signingKey: signingKey)
    }

    public func pause() async {
        await vaultClient.pause()
    }

    public func resume() async {
        await vaultClient.resume()
        await deviceManager.syncToDatabase()
    }

    // MARK: - Key Sharing (delegates to VaultKeyCoordinator)

    public func shareAllKeys() async throws {
        let peerNames = await deviceManager.pendingPeerDeviceNames
        try await keyCoordinator.shareAllKeys(pendingPeerDeviceNames: peerNames)
        await deviceManager.clearPendingPeerNames()
    }

    // MARK: - Device Management (delegates to VaultDeviceManager)

    public func listDevices() async throws -> [VaultDevice] {
        try await deviceManager.listDevices()
    }

    public func addMember(inboxId: String) async throws {
        try await deviceManager.addMember(inboxId: inboxId)
        await keyCoordinator.checkUnsharedInboxes()
    }

    public func removeDevice(inboxId: String) async throws {
        try await deviceManager.removeDevice(inboxId: inboxId)
    }

    public func broadcastConversationDeleted(inboxId: String, clientId: String) async {
        guard hasMultipleDevices else { return }

        let deletion = ConversationDeletedContent(
            inboxId: inboxId,
            clientId: clientId
        )

        do {
            try await vaultClient.send(deletion, codec: ConversationDeletedCodec())
            Log.info("Broadcast conversation deletion to vault: inboxId=\(inboxId)")
        } catch {
            Log.error("Failed to broadcast conversation deletion: \(error)")
        }
    }

    public func clearVaultKeyStore() async throws {
        try await vaultKeyStore?.deleteAll()
    }

    public func unpairSelf() async throws {
        guard let selfInboxId = await vaultInboxId else {
            throw VaultClientError.notConnected
        }

        let removal = DeviceRemovedContent(
            removedInboxId: selfInboxId,
            reason: .userRemoved
        )

        try await vaultClient.send(removal, codec: DeviceRemovedCodec())
        await cleanupLocalVaultState(inboxId: selfInboxId, preserveICloudBackupKey: true)
    }

    private func cleanupLocalVaultState(inboxId: String?, preserveICloudBackupKey: Bool) async {
        await vaultClient.disconnect()

        if let inboxId {
            if preserveICloudBackupKey {
                try? await vaultKeyStore?.deleteLocal(inboxId: inboxId)
            } else {
                try? await vaultKeyStore?.delete(inboxId: inboxId)
            }
        }

        if let databaseWriter {
            let writer = VaultDeviceWriter(dbWriter: databaseWriter)
            try? await writer.replaceAll([])
        }

        await keyCoordinator.stopObserving()
        bootstrapState = .notStarted
    }

    func handleSelfRemoved() async {
        Log.info("This device was removed from the vault by another device")
        let selfInboxId = await vaultInboxId
        await cleanupLocalVaultState(inboxId: selfInboxId, preserveICloudBackupKey: false)
    }

    public static var preview: VaultManager {
        VaultManager(
            identityStore: MockKeychainIdentityStore(),
            databaseReader: try! DatabaseQueue(), // swiftlint:disable:this force_try
            deviceName: "Preview Device"
        )
    }
}

// MARK: - VaultClientDelegate

extension VaultManager: VaultClientDelegate {
    nonisolated public func vaultClient(_ client: VaultClient, didReceiveKeyBundle bundle: DeviceKeyBundleContent, from senderInboxId: String) {
        Task {
            await self.deviceManager.syncToDatabase()
            await self.keyCoordinator.importKeyBundle(bundle)
        }
    }

    nonisolated public func vaultClient(_ client: VaultClient, didReceiveKeyShare share: DeviceKeyShareContent, from senderInboxId: String) {
        Task {
            await self.deviceManager.syncToDatabase()
            await self.keyCoordinator.importKeyShare(share)
        }
    }

    nonisolated public func vaultClient(_ client: VaultClient, didReceiveDeviceRemoved removal: DeviceRemovedContent, from senderInboxId: String) {
        Log.info("Device removed from vault: \(removal.removedInboxId), reason: \(removal.reason)")
        Task {
            let selfInboxId = await self.vaultInboxId
            if removal.removedInboxId == selfInboxId {
                await self.handleSelfRemoved()
            } else {
                await self.deviceManager.syncToDatabase()
            }
        }
    }

    nonisolated public func vaultClient(_ client: VaultClient, didReceiveConversationDeleted deletion: ConversationDeletedContent, from senderInboxId: String) {
        Log.info("Received conversation deletion from vault: inboxId=\(deletion.inboxId), clientId=\(deletion.clientId)")
        Task {
            await self.eventHandler?.vaultDidDeleteConversation(inboxId: deletion.inboxId, clientId: deletion.clientId)
        }
    }

    nonisolated public func vaultClient(_ client: VaultClient, didChangeState state: VaultClientState) {}

    nonisolated public func vaultClient(_ client: VaultClient, didEncounterError error: any Error) {
        Log.error("VaultClient error: \(error)")
    }
}

public enum VaultReCreateError: Error, LocalizedError {
    case bootstrapFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bootstrapFailed(let reason):
            return "Vault re-create failed during bootstrap: \(reason)"
        }
    }
}
