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
            let identity = try await loadOrCreateVaultIdentity(vaultKeyStore: vaultKeyStore)

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

            try await connect(signingKey: signingKey, options: options)

            guard let inboxId = await vaultInboxId,
                  let installationId = await vaultClient.installationId else {
                throw VaultClientError.notConnected
            }

            if identity.inboxId == "vault-pending" || identity.clientId != installationId {
                if identity.inboxId == "vault-pending" {
                    try? await vaultKeyStore.delete(inboxId: "vault-pending")
                } else {
                    try? await vaultKeyStore.delete(inboxId: inboxId)
                }
                _ = try? await vaultKeyStore.save(
                    inboxId: inboxId,
                    clientId: installationId,
                    keys: identity.keys
                )
            }

            let inboxWriter = InboxWriter(dbWriter: databaseWriter)
            try await inboxWriter.save(inboxId: inboxId, clientId: installationId, isVault: true)
            bootstrapState = .ready
            Log.info("Vault bootstrapped: inboxId=\(inboxId)")
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
            return existing
        }
        let newKeys = try KeychainIdentityKeys.generate()
        return try await vaultKeyStore.save(
            inboxId: "vault-pending",
            clientId: "vault-pending",
            keys: newKeys
        )
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
        Log.info("[Vault] reCreate: tearing down current vault")

        let oldInboxId = await vaultInboxId

        await vaultClient.disconnect()
        bootstrapState = .notStarted

        if let vaultKeyStore, let oldInboxId {
            do {
                try await vaultKeyStore.delete(inboxId: oldInboxId)
                Log.info("[Vault] reCreate: deleted old vault key for inboxId=\(oldInboxId)")
            } catch {
                Log.warning("[Vault] reCreate: failed to delete old vault key: \(error)")
            }
        } else if let vaultKeyStore {
            // No known inboxId (e.g., disconnect failed before we captured it) — delete all
            try? await vaultKeyStore.deleteAll()
            Log.info("[Vault] reCreate: deleted all vault keys (no specific inboxId)")
        }

        if let oldInboxId {
            do {
                try await databaseWriter.write { db in
                    try db.execute(
                        sql: "DELETE FROM inbox WHERE inboxId = ? AND isVault = 1",
                        arguments: [oldInboxId]
                    )
                }
                Log.info("[Vault] reCreate: deleted old DBInbox row for inboxId=\(oldInboxId)")
            } catch {
                Log.warning("[Vault] reCreate: failed to delete old DBInbox row: \(error)")
            }
        }

        Log.info("[Vault] reCreate: bootstrapping fresh vault")
        await bootstrapVault(databaseWriter: databaseWriter, environment: environment)

        guard case .ready = bootstrapState else {
            throw VaultReCreateError.bootstrapFailed(stateDescription)
        }

        let newInboxId = await vaultInboxId ?? "unknown"
        Log.info("[Vault] reCreate: completed, new inboxId=\(newInboxId)")
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
