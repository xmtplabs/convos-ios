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
    var pendingPeerDeviceNames: [String: String] = [:]
    var inboxObservationCancellable: AnyCancellable?

    public weak var delegate: (any VaultManagerDelegate)?
    public weak var eventHandler: (any VaultEventHandler)?

    var dmStreamTask: Task<Void, Never>?
    var activePairingSlug: String?
    var joinerDmStreamTask: Task<Void, Never>?
    var inboxesBeingShared: Set<String> = []

    public private(set) var bootstrapState: VaultBootstrapState = .notStarted

    public var isConnected: Bool {
        get async {
            if case .connected = await vaultClient.currentState { return true }
            return false
        }
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
        self.vaultClient = VaultClient()
        self.identityStore = identityStore
        self.vaultKeyStore = vaultKeyStore
        self.databaseReader = databaseReader
        self.deviceName = deviceName
    }

    public func setDelegate(_ delegate: any VaultManagerDelegate) {
        self.delegate = delegate
    }

    public func setEventHandler(_ handler: any VaultEventHandler) {
        self.eventHandler = handler
    }

    public func connect(signingKey: SigningKey, options: ClientOptions) async throws {
        await vaultClient.setDelegate(self)
        try await vaultClient.connect(signingKey: signingKey, options: options)
        await syncDevicesToDatabase()
    }

    public func bootstrapVault(
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment
    ) async {
        self.databaseWriter = databaseWriter

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

            if identity.inboxId == "vault-pending" {
                try? await vaultKeyStore.delete(inboxId: "vault-pending")
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
            startObservingInboxes()
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

    public func pause() async {
        await vaultClient.pause()
    }

    public func resume() async {
        await vaultClient.resume()
        await syncDevicesToDatabase()
    }

    // MARK: - Key Sharing

    public func shareAllKeys() async throws {
        guard let installationId = await vaultClient.installationId else {
            throw VaultClientError.notConnected
        }

        let inboxRows = try await databaseReader.read { db -> [InboxConversationRow] in
            let sql = """
                SELECT i.inboxId, i.clientId, c.id as conversationId
                FROM inbox i
                INNER JOIN conversation c ON c.clientId = i.clientId
                    AND c.id NOT LIKE 'draft-%'
                    AND c.isUnused = 0
                WHERE i.isVault = 0
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                InboxConversationRow(
                    inboxId: row["inboxId"],
                    clientId: row["clientId"],
                    conversationId: row["conversationId"] ?? ""
                )
            }
        }

        var keys: [DeviceKeyEntry] = []
        for item in inboxRows {
            guard let identity = try? await identityStore.identity(for: item.inboxId) else { continue }
            keys.append(DeviceKeyEntry(
                conversationId: item.conversationId,
                inboxId: item.inboxId,
                clientId: item.clientId,
                privateKeyData: Data(identity.keys.privateKey.secp256K1.bytes),
                databaseKey: identity.keys.databaseKey
            ))
        }

        let peerNames = pendingPeerDeviceNames.isEmpty ? nil : pendingPeerDeviceNames
        let bundle = DeviceKeyBundleContent(
            keys: keys,
            senderInstallationId: installationId,
            senderDeviceName: deviceName,
            peerDeviceNames: peerNames
        )

        try await vaultClient.send(bundle, codec: DeviceKeyBundleCodec())
        pendingPeerDeviceNames.removeAll()
        if let databaseWriter, !inboxRows.isEmpty {
            let inboxIds = inboxRows.map { $0.inboxId }
            try? await databaseWriter.write { db in
                for id in inboxIds {
                    try db.execute(
                        sql: "UPDATE inbox SET sharedToVault = 1 WHERE inboxId = ?",
                        arguments: [id]
                    )
                }
            }
        }
    }

    // MARK: - Device Management

    public func listDevices() async throws -> [VaultDevice] {
        let dbDevices = try VaultDeviceRepository(dbReader: databaseReader).fetchAll()
        if dbDevices.isEmpty {
            return [VaultDevice(inboxId: await vaultInboxId ?? "self", name: deviceName, isCurrentDevice: true)]
        }
        return dbDevices.map { VaultDevice(inboxId: $0.inboxId, name: $0.name, isCurrentDevice: $0.isCurrentDevice) }
    }

    public func addMember(inboxId: String) async throws {
        try await vaultClient.addMember(inboxId: inboxId)
        await syncDevicesToDatabase()
        await checkUnsharedInboxes()
    }

    public func removeDevice(inboxId: String) async throws {
        let removal = DeviceRemovedContent(
            removedInboxId: inboxId,
            reason: .userRemoved
        )

        try await vaultClient.send(removal, codec: DeviceRemovedCodec())
        try await vaultClient.removeMember(inboxId: inboxId)
        await syncDevicesToDatabase()
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

    public func unpairSelf() async throws {
        guard let selfInboxId = await vaultInboxId else {
            throw VaultClientError.notConnected
        }

        let removal = DeviceRemovedContent(
            removedInboxId: selfInboxId,
            reason: .userRemoved
        )

        try await vaultClient.send(removal, codec: DeviceRemovedCodec())
        await cleanupLocalVaultState(inboxId: selfInboxId)
    }

    private func cleanupLocalVaultState(inboxId: String?) async {
        await vaultClient.disconnect()

        if let inboxId {
            try? await vaultKeyStore?.delete(inboxId: inboxId)
        }

        if let databaseWriter {
            let writer = VaultDeviceWriter(dbWriter: databaseWriter)
            try? await writer.replaceAll([])
        }

        inboxObservationCancellable?.cancel()
        inboxObservationCancellable = nil
        bootstrapState = .notStarted
    }

    func handleSelfRemoved() async {
        Log.info("This device was removed from the vault by another device")
        let selfInboxId = await vaultInboxId
        await cleanupLocalVaultState(inboxId: selfInboxId)
    }

    func syncDevicesToDatabase() async {
        guard let databaseWriter else { return }
        guard let selfInboxId = await vaultInboxId else { return }

        do {
            let members = try await vaultClient.members()

            let existingNames = try VaultDeviceRepository(dbReader: databaseReader)
                .fetchAll()
                .reduce(into: [String: String]()) { $0[$1.inboxId] = $1.name }

            let unknownMembers = members.filter { member in
                member.inboxId != selfInboxId
                    && pendingPeerDeviceNames[member.inboxId] == nil
                    && existingNames[member.inboxId] == nil
            }

            var messageNames: [String: String] = [:]
            if !unknownMembers.isEmpty {
                messageNames = try await loadDeviceNames()
            }

            let writer = VaultDeviceWriter(dbWriter: databaseWriter)

            let devices = members.map { member in
                let isSelf = member.inboxId == selfInboxId
                let name: String
                if isSelf {
                    name = deviceName
                } else {
                    name = pendingPeerDeviceNames[member.inboxId]
                        ?? existingNames[member.inboxId]
                        ?? messageNames[member.inboxId]
                        ?? "Unknown device"
                }
                return DBVaultDevice(
                    inboxId: member.inboxId,
                    name: name,
                    isCurrentDevice: isSelf
                )
            }

            try await writer.replaceAll(devices)
        } catch {
            Log.error("Failed to sync vault devices to database: \(error)")
        }
    }

    public static var preview: VaultManager {
        VaultManager(
            identityStore: MockKeychainIdentityStore(),
            databaseReader: try! DatabaseQueue(), // swiftlint:disable:this force_try
            deviceName: "Preview Device"
        )
    }

    struct InboxConversationRow {
        let inboxId: String
        let clientId: String
        let conversationId: String
    }

    private func loadDeviceNames() async -> [String: String] {
        guard let messages = try? await vaultClient.vaultGroupMessages() else { return [:] }

        var names: [String: String] = [:]
        for message in messages {
            if let bundle: DeviceKeyBundleContent = try? message.content() {
                if let name = bundle.senderDeviceName {
                    names[message.senderInboxId] = name
                }
                if let peers = bundle.peerDeviceNames {
                    for (inboxId, peerName) in peers {
                        names[inboxId] = peerName
                    }
                }
            } else if let share: DeviceKeyShareContent = try? message.content(),
                      let name = share.senderDeviceName {
                names[message.senderInboxId] = name
            }
        }
        return names
    }
}

// MARK: - VaultClientDelegate

extension VaultManager: VaultClientDelegate {
    nonisolated public func vaultClient(_ client: VaultClient, didReceiveKeyBundle bundle: DeviceKeyBundleContent, from senderInboxId: String) {
        Task {
            await self.syncDevicesToDatabase()
            await self.importKeyBundle(bundle)
        }
    }

    nonisolated public func vaultClient(_ client: VaultClient, didReceiveKeyShare share: DeviceKeyShareContent, from senderInboxId: String) {
        Task {
            await self.syncDevicesToDatabase()
            await self.importKeyShare(share)
        }
    }

    nonisolated public func vaultClient(_ client: VaultClient, didReceiveDeviceRemoved removal: DeviceRemovedContent, from senderInboxId: String) {
        Log.info("Device removed from vault: \(removal.removedInboxId), reason: \(removal.reason)")
        Task {
            let selfInboxId = await self.vaultInboxId
            if removal.removedInboxId == selfInboxId {
                await self.handleSelfRemoved()
            } else {
                await self.syncDevicesToDatabase()
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
