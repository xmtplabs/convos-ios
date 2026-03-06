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

    var dmStreamTask: Task<Void, Never>?
    var activePairingSlug: String?
    var joinerDmStreamTask: Task<Void, Never>?

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

        let identity: KeychainIdentity
        if let existing = try? await vaultKeyStore.loadAny() {
            identity = existing
        } else {
            guard let newKeys = try? KeychainIdentityKeys.generate() else {
                Log.error("Failed to generate vault identity keys")
                return
            }
            guard let saved = try? await vaultKeyStore.save(
                inboxId: "vault-pending",
                clientId: "vault-pending",
                keys: newKeys
            ) else {
                Log.error("Failed to save vault identity to keychain")
                return
            }
            identity = saved
        }

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
                TextCodec(),
            ],
            dbEncryptionKey: identity.keys.databaseKey
        )

        do {
            try await connect(signingKey: signingKey, options: options)

            guard let inboxId = await vaultInboxId,
                  let installationId = await vaultClient.installationId else {
                Log.error("Vault connected but missing inboxId or installationId")
                return
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
            try? await inboxWriter.save(inboxId: inboxId, clientId: installationId, isVault: true)
            Log.info("Vault bootstrapped: inboxId=\(inboxId)")
            startObservingInboxes()
        } catch {
            Log.error("Failed to bootstrap vault: \(error)")
        }
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
                LEFT JOIN conversation c ON c.clientId = i.clientId AND c.id NOT LIKE 'draft-%'
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
        await vaultClient.disconnect()
    }

    func syncDevicesToDatabase() async {
        guard let databaseWriter else { return }
        guard let selfInboxId = await vaultInboxId else { return }

        do {
            let members = try await vaultClient.members()
            let deviceNames = try await loadDeviceNames()
            let writer = VaultDeviceWriter(dbWriter: databaseWriter)

            let devices = members.map { member in
                let isSelf = member.inboxId == selfInboxId
                let name: String
                if isSelf {
                    name = deviceName
                } else {
                    name = pendingPeerDeviceNames[member.inboxId]
                        ?? deviceNames[member.inboxId]
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
    }

    nonisolated public func vaultClient(_ client: VaultClient, didReceiveConversationDeleted deletion: ConversationDeletedContent, from senderInboxId: String) {
        Log.info("Received conversation deletion from vault: inboxId=\(deletion.inboxId), clientId=\(deletion.clientId)")
        NotificationCenter.default.post(
            name: .vaultDidDeleteConversation,
            object: nil,
            userInfo: [
                "inboxId": deletion.inboxId,
                "clientId": deletion.clientId,
            ]
        )
    }

    nonisolated public func vaultClient(_ client: VaultClient, didChangeState state: VaultClientState) {}

    nonisolated public func vaultClient(_ client: VaultClient, didEncounterError error: any Error) {
        Log.error("VaultClient error: \(error)")
    }
}
