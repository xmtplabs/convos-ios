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
    private var databaseWriter: (any DatabaseWriter)?
    private let deviceName: String
    private var pendingPeerDeviceNames: [String: String] = [:]
    private var inboxObservationCancellable: AnyCancellable?

    public weak var delegate: (any VaultManagerDelegate)?

    public var isConnected: Bool {
        if case .connected = vaultClient.state { return true }
        return false
    }

    public var hasMultipleDevices: Bool {
        let count = (try? VaultDeviceRepository(dbReader: databaseReader).count()) ?? 0
        return count > 1
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

            guard let inboxId = vaultInboxId,
                  let installationId = vaultClient.installationId else {
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

    private func startObservingInboxes() {
        let observation = ValueObservation.tracking { db in
            try Self.fetchUnsharedRows(db)
        }

        inboxObservationCancellable = observation
            .publisher(in: databaseReader)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] unsharedRows in
                    guard let self, !unsharedRows.isEmpty else { return }
                    Task { await self.shareUnsharedInboxes(unsharedRows) }
                }
            )
        Log.info("Vault: started observing inboxes for key sharing")
    }

    private func shareUnsharedInboxes(_ rows: [InboxConversationRow]) async {
        guard isConnected, hasMultipleDevices, let databaseWriter else { return }
        Log.info("Vault: found \(rows.count) unshared inbox(es) with conversations")

        for row in rows {
            await shareKeyForInbox(row.inboxId, clientId: row.clientId)

            try? await databaseWriter.write { db in
                try db.execute(
                    sql: "UPDATE inbox SET sharedToVault = 1 WHERE inboxId = ?",
                    arguments: [row.inboxId]
                )
            }
        }
    }

    private func shareKeyForInbox(_ inboxId: String, clientId: String) async {
        guard let identity = try? await identityStore.identity(for: inboxId) else {
            Log.warning("Vault: no keychain identity for inbox \(inboxId)")
            return
        }

        let conversationId = try? await databaseReader.read { db -> String? in
            let sql = """
                SELECT c.id FROM conversation c
                WHERE c.clientId = ? AND c.id NOT LIKE 'draft-%'
                LIMIT 1
                """
            return try String.fetchOne(db, sql: sql, arguments: [clientId])
        }

        let keyInfo = InboxKeyInfo(
            inboxId: inboxId,
            clientId: clientId,
            conversationId: conversationId ?? "",
            privateKeyData: Data(identity.keys.privateKey.secp256K1.bytes),
            databaseKey: identity.keys.databaseKey
        )
        Log.info("Vault: sharing key for inbox \(inboxId)")
        await shareKeyFromNotification(keyInfo)
    }

    public func disconnect() {
        vaultClient.disconnect()
    }

    public func pause() {
        vaultClient.pause()
    }

    public func resume() async {
        await vaultClient.resume()
        await syncDevicesToDatabase()
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
            senderInstallationId: installationId,
            senderDeviceName: deviceName
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

    func shareKeyFromNotification(_ keyInfo: InboxKeyInfo) async {
        guard isConnected, hasMultipleDevices, let installationId = vaultClient.installationId else { return }
        let share = DeviceKeyShareContent(
            conversationId: keyInfo.conversationId,
            inboxId: keyInfo.inboxId,
            clientId: keyInfo.clientId,
            privateKeyData: keyInfo.privateKeyData,
            databaseKey: keyInfo.databaseKey,
            senderInstallationId: installationId,
            senderDeviceName: deviceName
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
        guard let group = vaultClient.vaultGroup else { throw PairingError.noVaultGroup }
        guard let client = vaultClient.xmtpClient, let vaultInboxId, let vaultKeyStore else {
            throw VaultClientError.notConnected
        }

        let identity = try await vaultKeyStore.load(inboxId: vaultInboxId)
        let privateKey: Data = identity.keys.privateKey.secp256K1.bytes

        try await group.ensureInviteTag()

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

    public func lockVault() async {
        guard let group = vaultClient.vaultGroup else { return }
        try? await group.clearInviteTag()
    }
    public func stopPairing() async {
        dmStreamTask?.cancel()
        dmStreamTask = nil
        if activePairingSlug != nil {
            activePairingSlug = nil
            await lockVault()
        }
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
                    Log.error("Vault: DM stream error: \(error)")
                    await self.delegate?.vaultManager(self, didEncounterError: error)
                }
            }
        }
    }

    private func handleDmMessage(_ message: DecodedMessage) async {
        guard let activePairingSlug else {
            return
        }
        guard let vaultInboxId, message.senderInboxId != vaultInboxId else {
            return
        }

        var request: PairingJoinRequest?

        if let joinRequest: JoinRequestContent = try? message.content(),
           joinRequest.inviteSlug == activePairingSlug {
            let pin = joinRequest.metadata?["pin"] ?? ""
            let name = joinRequest.metadata?["deviceName"] ?? "Unknown device"
            request = PairingJoinRequest(
                pin: pin,
                deviceName: name,
                joinerInboxId: message.senderInboxId
            )
        } else if let text: String = try? message.content(),
                  text == activePairingSlug {
            request = PairingJoinRequest(pin: "", deviceName: "Unknown device", joinerInboxId: message.senderInboxId)
        }

        guard let request else { return }

        pendingPeerDeviceNames[request.joinerInboxId] = request.deviceName
        await lockVault()
        self.activePairingSlug = nil
        dmStreamTask?.cancel()
        dmStreamTask = nil

        delegate?.vaultManager(self, didReceivePairingJoinRequest: request)
    }

    public func sendPairingError(to joinerInboxId: String, message: String) async {
        do {
            let dm = try await vaultClient.findOrCreateDm(with: joinerInboxId)
            _ = try await dm.send(content: "PAIRING_ERROR:\(message)")
        } catch {
            Log.error("Failed to send pairing error to joiner: \(error)")
        }
    }

    // MARK: - Pairing (Joiner - Device B)

    private var joinerDmStreamTask: Task<Void, Never>?

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
        startJoinerDmStream()
    }

    private func startJoinerDmStream() {
        joinerDmStreamTask?.cancel()
        joinerDmStreamTask = Task { [weak self] in
            guard let self else { return }

            async let dmStream: Void = {
                do {
                    let stream = await self.vaultClient.streamAllDmMessages()
                    for try await message in stream {
                        guard !Task.isCancelled else { break }
                        await self.handleJoinerDmMessage(message)
                    }
                } catch {
                    if !Task.isCancelled {
                        Log.error("Joiner DM stream error: \(error)")
                    }
                }
            }()

            async let vaultPoll: Void = {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { break }
                    do {
                        try await self.vaultClient.resyncVaultGroup()
                        let messages = try await self.vaultClient.vaultGroupMessages()
                        for message in messages {
                            if let bundle: DeviceKeyBundleContent = try? message.content(),
                               !bundle.keys.isEmpty {
                                await self.importKeyBundle(bundle)
                                return
                            }
                        }
                    } catch {
                        continue
                    }
                }
            }()

            _ = await (dmStream, vaultPoll)
        }
    }

    private func handleJoinerDmMessage(_ message: DecodedMessage) async {
        guard let vaultInboxId, message.senderInboxId != vaultInboxId else { return }

        if let text: String = try? message.content(),
           text.hasPrefix("PAIRING_ERROR:") {
            let errorMessage = String(text.dropFirst("PAIRING_ERROR:".count))
            joinerDmStreamTask?.cancel()
            joinerDmStreamTask = nil
            NotificationCenter.default.post(
                name: .vaultPairingError,
                object: nil,
                userInfo: ["message": errorMessage]
            )
        }
    }

    public func stopJoinerPairing() {
        joinerDmStreamTask?.cancel()
        joinerDmStreamTask = nil
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

    public func listDevices() throws -> [VaultDevice] {
        let dbDevices = try VaultDeviceRepository(dbReader: databaseReader).fetchAll()
        if dbDevices.isEmpty {
            return [VaultDevice(inboxId: vaultInboxId ?? "self", name: deviceName, isCurrentDevice: true)]
        }
        return dbDevices.map { VaultDevice(inboxId: $0.inboxId, name: $0.name, isCurrentDevice: $0.isCurrentDevice) }
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

    public func addMember(inboxId: String) async throws {
        try await vaultClient.addMember(inboxId: inboxId)
        await syncDevicesToDatabase()
        await checkUnsharedInboxes()
    }

    private func checkUnsharedInboxes() async {
        guard isConnected, hasMultipleDevices else { return }
        guard let rows = try? await databaseReader.read({ db in
            try Self.fetchUnsharedRows(db)
        }), !rows.isEmpty else { return }
        await shareUnsharedInboxes(rows)
    }

    private static func fetchUnsharedRows(_ db: Database) throws -> [InboxConversationRow] {
        let sql = """
            SELECT i.inboxId, i.clientId, c.id as conversationId
            FROM inbox i
            INNER JOIN conversation c ON c.clientId = i.clientId
                AND c.id NOT LIKE 'draft-%'
                AND c.isUnused = 0
            WHERE i.isVault = 0 AND i.sharedToVault = 0
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            InboxConversationRow(
                inboxId: row["inboxId"],
                clientId: row["clientId"],
                conversationId: row["conversationId"] ?? ""
            )
        }
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

    private func syncDevicesToDatabase() async {
        guard let databaseWriter else { return }
        guard let selfInboxId = vaultInboxId else { return }

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

            if let databaseWriter {
                let inboxWriter = InboxWriter(dbWriter: databaseWriter)
                try await inboxWriter.save(inboxId: identity.inboxId, clientId: identity.clientId)
            }

            let entry = VaultIdentityEntry(
                inboxId: identity.inboxId,
                clientId: identity.clientId,
                privateKeyData: share.privateKeyData,
                databaseKey: share.databaseKey
            )
            delegate?.vaultManager(self, didImportKey: entry)
            postImportNotification(inboxId: identity.inboxId, clientId: identity.clientId)
        } catch {
            delegate?.vaultManager(self, didEncounterError: error)
        }
    }

    private func importKeyBundle(_ bundle: DeviceKeyBundleContent) async {
        var importedEntries: [(inboxId: String, clientId: String)] = []
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

                if let databaseWriter {
                    let inboxWriter = InboxWriter(dbWriter: databaseWriter)
                    try await inboxWriter.save(inboxId: identity.inboxId, clientId: identity.clientId)
                }

                let entry = VaultIdentityEntry(
                    inboxId: identity.inboxId,
                    clientId: identity.clientId,
                    privateKeyData: key.privateKeyData,
                    databaseKey: key.databaseKey
                )
                delegate?.vaultManager(self, didImportKey: entry)
                importedEntries.append((inboxId: identity.inboxId, clientId: identity.clientId))
            } catch {
                delegate?.vaultManager(self, didEncounterError: error)
            }
        }

        if !importedEntries.isEmpty {
            for entry in importedEntries {
                postImportNotification(inboxId: entry.inboxId, clientId: entry.clientId)
            }
            NotificationCenter.default.post(
                name: .vaultDidReceiveKeyBundle,
                object: nil,
                userInfo: ["importedCount": importedEntries.count]
            )
        }
    }

    private func postImportNotification(inboxId: String, clientId: String) {
        NotificationCenter.default.post(
            name: .vaultDidImportInbox,
            object: nil,
            userInfo: ["inboxId": inboxId, "clientId": clientId]
        )
    }

    private func hasIdentity(for inboxId: String) async -> Bool {
        (try? await identityStore.identity(for: inboxId)) != nil
    }
}

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
        Task { await delegate?.vaultManager(self, didRemoveDevice: removal.removedInboxId) }
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
        Task { await delegate?.vaultManager(self, didEncounterError: error) }
    }
}
