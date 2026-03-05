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

public struct VaultIdentityEntry: Codable, Sendable {
    public let inboxId: String
    public let clientId: String
    public let privateKeyData: Data
    public let databaseKey: Data

    public init(
        inboxId: String,
        clientId: String,
        privateKeyData: Data,
        databaseKey: Data
    ) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.privateKeyData = privateKeyData
        self.databaseKey = databaseKey
    }
}

public struct PairingJoinRequest: Sendable {
    public let pin: String
    public let deviceName: String
    public let joinerInboxId: String
}

public protocol VaultManagerDelegate: AnyObject, Sendable {
    func vaultManager(_ manager: VaultManager, didImportKey entry: VaultIdentityEntry)
    func vaultManager(_ manager: VaultManager, didRemoveDevice inboxId: String)
    func vaultManager(_ manager: VaultManager, didReceivePairingJoinRequest request: PairingJoinRequest)
    func vaultManager(_ manager: VaultManager, didEncounterError error: any Error)
}

public extension VaultManagerDelegate {
    func vaultManager(_ manager: VaultManager, didImportKey entry: VaultIdentityEntry) {}
    func vaultManager(_ manager: VaultManager, didRemoveDevice inboxId: String) {}
    func vaultManager(_ manager: VaultManager, didReceivePairingJoinRequest request: PairingJoinRequest) {}
    func vaultManager(_ manager: VaultManager, didEncounterError error: any Error) {}
}

public actor VaultManager {
    private let vaultClient: VaultClient
    private let identityStore: any KeychainIdentityStoreProtocol
    private let vaultKeyStore: VaultKeyStore?
    private let databaseReader: any DatabaseReader
    private let deviceName: String
    private var memberCount: Int = 1

    public weak var delegate: (any VaultManagerDelegate)?

    public var isConnected: Bool {
        if case .connected = vaultClient.state { return true }
        return false
    }

    public var hasMultipleDevices: Bool {
        memberCount > 1
    }

    public nonisolated var vaultInboxId: String? {
        vaultClient.inboxId
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
        vaultClient.delegate = self
        try await vaultClient.connect(signingKey: signingKey, options: options)
        await refreshMemberCount()
    }

    public func disconnect() {
        vaultClient.disconnect()
    }

    public func pause() {
        vaultClient.pause()
    }

    public func resume() async {
        await vaultClient.resume()
        await refreshMemberCount()
    }

    public func shareKey(_ entry: VaultIdentityEntry) async throws {
        guard let installationId = vaultClient.installationId else {
            throw VaultClientError.notConnected
        }

        let share = DeviceKeyShareContent(
            conversationId: "",
            inboxId: entry.inboxId,
            clientId: entry.clientId,
            privateKeyData: entry.privateKeyData,
            databaseKey: entry.databaseKey,
            senderInstallationId: installationId
        )

        try await vaultClient.send(share, codec: DeviceKeyShareCodec())
    }

    public func shareAllKeys() async throws {
        guard let installationId = vaultClient.installationId else {
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

        let bundle = DeviceKeyBundleContent(
            keys: keys,
            senderInstallationId: installationId
        )

        try await vaultClient.send(bundle, codec: DeviceKeyBundleCodec())
    }

    func shareKeyFromNotification(_ keyInfo: InboxKeyInfo) async {
        guard isConnected, hasMultipleDevices else { return }
        guard let installationId = vaultClient.installationId else { return }

        let share = DeviceKeyShareContent(
            conversationId: keyInfo.conversationId,
            inboxId: keyInfo.inboxId,
            clientId: keyInfo.clientId,
            privateKeyData: keyInfo.privateKeyData,
            databaseKey: keyInfo.databaseKey,
            senderInstallationId: installationId
        )

        do {
            try await vaultClient.send(share, codec: DeviceKeyShareCodec())
        } catch {
            delegate?.vaultManager(self, didEncounterError: error)
        }
    }

    // MARK: - Pairing (Initiator - Device A)

    private var dmStreamTask: Task<Void, Never>?
    private var activePairingSlug: String?

    public func createPairingInvite(expiresAt: Date) async throws -> String {
        guard let group = vaultClient.vaultGroup else {
            throw PairingError.noVaultGroup
        }
        guard let client = vaultClient.xmtpClient else {
            throw VaultClientError.notConnected
        }
        guard let vaultInboxId, let vaultKeyStore else {
            throw VaultClientError.notConnected
        }

        let identity = try await vaultKeyStore.load(inboxId: vaultInboxId)
        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes

        let coordinator = InviteCoordinator(
            privateKeyProvider: { _ in privateKey },
            tagStorage: ProtobufInviteTagStorage()
        )

        let adapter = VaultInviteClientAdapter(client: client)
        let result = try await coordinator.createInvite(
            for: group,
            client: adapter,
            options: InviteOptions(expiresAt: expiresAt, singleUse: true)
        )

        activePairingSlug = result.slug
        startDmStream()
        return result.slug
    }

    public func stopPairingListener() {
        dmStreamTask?.cancel()
        dmStreamTask = nil
        activePairingSlug = nil
    }

    private func startDmStream() {
        dmStreamTask?.cancel()
        dmStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.vaultClient.streamAllDmMessages()
                for try await message in stream {
                    guard !Task.isCancelled else { break }
                    await self.handleDmMessage(message)
                }
            } catch {
                if !Task.isCancelled {
                    await self.delegate?.vaultManager(self, didEncounterError: error)
                }
            }
        }
    }

    private func handleDmMessage(_ message: DecodedMessage) {
        guard let activePairingSlug else { return }
        guard let vaultInboxId, message.senderInboxId != vaultInboxId else { return }

        if let joinRequest: JoinRequestContent = try? message.content(),
           joinRequest.inviteSlug == activePairingSlug {
            let pin = joinRequest.metadata?["pin"] ?? ""
            let name = joinRequest.metadata?["deviceName"] ?? "Unknown device"
            let request = PairingJoinRequest(
                pin: pin,
                deviceName: name,
                joinerInboxId: message.senderInboxId
            )
            delegate?.vaultManager(self, didReceivePairingJoinRequest: request)
            return
        }

        if let text: String = try? message.content(),
           text == activePairingSlug {
            let request = PairingJoinRequest(
                pin: "",
                deviceName: "Unknown device",
                joinerInboxId: message.senderInboxId
            )
            delegate?.vaultManager(self, didReceivePairingJoinRequest: request)
        }
    }

    // MARK: - Pairing (Joiner - Device B)

    public func sendPairingJoinRequest(
        slug: String,
        pin: String,
        deviceName: String
    ) async throws {
        guard let client = vaultClient.xmtpClient else {
            throw VaultClientError.notConnected
        }

        guard let signedInvite = try? SignedInvite.fromURLSafeSlug(slug) else {
            throw PairingError.invalidInviteSlug
        }

        let adapter = VaultInviteClientAdapter(client: client)
        let coordinator = InviteCoordinator(
            privateKeyProvider: { _ in Data() },
            tagStorage: ProtobufInviteTagStorage()
        )

        _ = try await coordinator.sendJoinRequest(
            for: signedInvite,
            client: adapter,
            metadata: [
                "pin": pin,
                "deviceName": deviceName,
            ]
        )
    }

    public static var preview: VaultManager {
        VaultManager(
            identityStore: MockKeychainIdentityStore(),
            databaseReader: try! DatabaseQueue(), // swiftlint:disable:this force_try
            deviceName: "Preview Device"
        )
    }

    private struct InboxConversationRow {
        let inboxId: String
        let clientId: String
        let conversationId: String
    }

    public func listDevices() async throws -> [VaultDevice] {
        let members = try await vaultClient.members()
        let currentInboxId = vaultClient.inboxId

        return members.map { member in
            VaultDevice(
                inboxId: member.inboxId,
                name: member.inboxId == currentInboxId ? deviceName : member.inboxId,
                isCurrentDevice: member.inboxId == currentInboxId
            )
        }
    }

    public func addMember(inboxId: String) async throws {
        try await vaultClient.addMember(inboxId: inboxId)
        await refreshMemberCount()
    }

    public func removeDevice(inboxId: String) async throws {
        let removal = DeviceRemovedContent(
            removedInboxId: inboxId,
            reason: .userRemoved
        )

        try await vaultClient.send(removal, codec: DeviceRemovedCodec())
        try await vaultClient.removeMember(inboxId: inboxId)
        await refreshMemberCount()
    }

    public func unpairSelf() async throws {
        guard let selfInboxId = vaultInboxId else {
            throw VaultClientError.notConnected
        }

        let removal = DeviceRemovedContent(
            removedInboxId: selfInboxId,
            reason: .userRemoved
        )

        try await vaultClient.send(removal, codec: DeviceRemovedCodec())
        vaultClient.disconnect()
    }

    private func refreshMemberCount() async {
        memberCount = (try? await vaultClient.members().count) ?? 1
    }

    private func importKeyShare(_ share: DeviceKeyShareContent) async {
        guard await !hasIdentity(for: share.inboxId) else { return }

        do {
            let keys = try KeychainIdentityKeys(
                privateKeyData: share.privateKeyData,
                databaseKey: share.databaseKey
            )
            let identity = try await identityStore.save(
                inboxId: share.inboxId,
                clientId: share.clientId,
                keys: keys
            )
            let entry = VaultIdentityEntry(
                inboxId: identity.inboxId,
                clientId: identity.clientId,
                privateKeyData: share.privateKeyData,
                databaseKey: share.databaseKey
            )
            delegate?.vaultManager(self, didImportKey: entry)
        } catch {
            delegate?.vaultManager(self, didEncounterError: error)
        }
    }

    private func importKeyBundle(_ bundle: DeviceKeyBundleContent) async {
        for key in bundle.keys {
            guard await !hasIdentity(for: key.inboxId) else { continue }

            do {
                let keys = try KeychainIdentityKeys(
                    privateKeyData: key.privateKeyData,
                    databaseKey: key.databaseKey
                )
                let identity = try await identityStore.save(
                    inboxId: key.inboxId,
                    clientId: key.clientId,
                    keys: keys
                )
                let entry = VaultIdentityEntry(
                    inboxId: identity.inboxId,
                    clientId: identity.clientId,
                    privateKeyData: key.privateKeyData,
                    databaseKey: key.databaseKey
                )
                delegate?.vaultManager(self, didImportKey: entry)
            } catch {
                delegate?.vaultManager(self, didEncounterError: error)
            }
        }
    }

    private func hasIdentity(for inboxId: String) async -> Bool {
        (try? await identityStore.identity(for: inboxId)) != nil
    }
}

extension VaultManager: VaultClientDelegate {
    nonisolated public func vaultClient(_ client: VaultClient, didReceiveKeyBundle bundle: DeviceKeyBundleContent, from senderInboxId: String) {
        Task { await importKeyBundle(bundle) }
    }

    nonisolated public func vaultClient(_ client: VaultClient, didReceiveKeyShare share: DeviceKeyShareContent, from senderInboxId: String) {
        Task { await importKeyShare(share) }
    }

    nonisolated public func vaultClient(_ client: VaultClient, didReceiveDeviceRemoved removal: DeviceRemovedContent, from senderInboxId: String) {
        Task { await delegate?.vaultManager(self, didRemoveDevice: removal.removedInboxId) }
    }

    nonisolated public func vaultClient(_ client: VaultClient, didChangeState state: VaultClientState) {}

    nonisolated public func vaultClient(_ client: VaultClient, didEncounterError error: any Error) {
        Task { await delegate?.vaultManager(self, didEncounterError: error) }
    }
}
