import Foundation
import GRDB
@preconcurrency import XMTPiOS

actor VaultDeviceManager {
    private let vaultClient: VaultClient
    private let databaseReader: any DatabaseReader
    private var databaseWriter: (any DatabaseWriter)?
    private let deviceName: String
    var pendingPeerDeviceNames: [String: String] = [:]

    init(
        vaultClient: VaultClient,
        databaseReader: any DatabaseReader,
        deviceName: String
    ) {
        self.vaultClient = vaultClient
        self.databaseReader = databaseReader
        self.deviceName = deviceName
    }

    func setDatabaseWriter(_ writer: any DatabaseWriter) {
        self.databaseWriter = writer
    }

    // MARK: - Public API

    func listDevices() async throws -> [VaultDevice] {
        let dbDevices = try VaultDeviceRepository(dbReader: databaseReader).fetchAll()
        if dbDevices.isEmpty {
            return [VaultDevice(inboxId: await vaultClient.inboxId ?? "self", name: deviceName, isCurrentDevice: true)]
        }
        return dbDevices.map { VaultDevice(inboxId: $0.inboxId, name: $0.name, isCurrentDevice: $0.isCurrentDevice) }
    }

    func addMember(inboxId: String) async throws {
        try await vaultClient.addMember(inboxId: inboxId)
        await syncToDatabase()
    }

    func removeDevice(inboxId: String) async throws {
        let removal = DeviceRemovedContent(
            removedInboxId: inboxId,
            reason: .userRemoved
        )

        try await vaultClient.send(removal, codec: DeviceRemovedCodec())
        try await vaultClient.removeMember(inboxId: inboxId)
        await syncToDatabase()
    }

    func handleSelfRemoved(vaultKeyStore: VaultKeyStore?) async {
        Log.info("This device was removed from the vault by another device")
        let selfInboxId = await vaultClient.inboxId
        await vaultClient.disconnect()

        if let selfInboxId {
            try? await vaultKeyStore?.delete(inboxId: selfInboxId)
        }

        if let databaseWriter {
            let writer = VaultDeviceWriter(dbWriter: databaseWriter)
            try? await writer.replaceAll([])
        }
    }

    func syncToDatabase() async {
        guard let databaseWriter else { return }
        guard let selfInboxId = await vaultClient.inboxId else { return }

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
                messageNames = await loadDeviceNames()
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

    func registerPeerDeviceName(_ name: String, for inboxId: String) {
        pendingPeerDeviceNames[inboxId] = name
    }

    func clearPendingPeerNames() {
        pendingPeerDeviceNames.removeAll()
    }

    var hasMultipleDevices: Bool {
        let count = (try? VaultDeviceRepository(dbReader: databaseReader).count()) ?? 0
        return count > 1
    }

    // MARK: - Private

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
