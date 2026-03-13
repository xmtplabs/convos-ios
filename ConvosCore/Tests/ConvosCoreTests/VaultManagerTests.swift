@testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

@Suite("VaultManager Tests")
struct VaultManagerTests {
    private func makeManager() throws -> (VaultManager, MockKeychainIdentityStore, DatabaseQueue) {
        let store = MockKeychainIdentityStore()
        let dbQueue = try DatabaseQueue()
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test iPhone")
        return (manager, store, dbQueue)
    }

    @Test("Import key share saves to identity store")
    func importKeyShare() async throws {
        let (manager, store, _) = try makeManager()

        let generatedKeys = try KeychainIdentityKeys.generate()
        let share = DeviceKeyShareContent(
            conversationId: "",
            inboxId: "inbox-1",
            clientId: "client-1",
            privateKeyData: Data(generatedKeys.privateKey.secp256K1.bytes),
            databaseKey: generatedKeys.databaseKey,
            senderInstallationId: "install-1"
        )

        await manager.vaultClient(VaultClient(), didReceiveKeyShare: share, from: "other-inbox")

        try await Task.sleep(for: .milliseconds(50))

        let identities = try await store.loadAll()
        #expect(identities.count == 1)
        #expect(identities[0].inboxId == "inbox-1")
        #expect(identities[0].clientId == "client-1")
    }

    @Test("Import key share skips duplicates")
    func importKeyShareSkipsDuplicates() async throws {
        let (manager, store, _) = try makeManager()

        let existingKeys = try KeychainIdentityKeys.generate()
        _ = try await store.save(inboxId: "inbox-1", clientId: "client-1", keys: existingKeys)

        let otherKeys = try KeychainIdentityKeys.generate()
        let share = DeviceKeyShareContent(
            conversationId: "",
            inboxId: "inbox-1",
            clientId: "client-1",
            privateKeyData: Data(otherKeys.privateKey.secp256K1.bytes),
            databaseKey: otherKeys.databaseKey,
            senderInstallationId: "install-1"
        )

        await manager.vaultClient(VaultClient(), didReceiveKeyShare: share, from: "other-inbox")

        try await Task.sleep(for: .milliseconds(50))

        let identities = try await store.loadAll()
        #expect(identities.count == 1)
        #expect(identities[0].keys.databaseKey == existingKeys.databaseKey)
    }

    @Test("Import key bundle saves multiple keys")
    func importKeyBundle() async throws {
        let (manager, store, _) = try makeManager()

        let keys1 = try KeychainIdentityKeys.generate()
        let keys2 = try KeychainIdentityKeys.generate()
        let keys3 = try KeychainIdentityKeys.generate()

        let bundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "", inboxId: "inbox-1", clientId: "client-1", privateKeyData: Data(keys1.privateKey.secp256K1.bytes), databaseKey: keys1.databaseKey),
                DeviceKeyEntry(conversationId: "", inboxId: "inbox-2", clientId: "client-2", privateKeyData: Data(keys2.privateKey.secp256K1.bytes), databaseKey: keys2.databaseKey),
                DeviceKeyEntry(conversationId: "", inboxId: "inbox-3", clientId: "client-3", privateKeyData: Data(keys3.privateKey.secp256K1.bytes), databaseKey: keys3.databaseKey),
            ],
            senderInstallationId: "install-1"
        )

        await manager.vaultClient(VaultClient(), didReceiveKeyBundle: bundle, from: "other-inbox")

        try await Task.sleep(for: .milliseconds(100))

        let identities = try await store.loadAll()
        #expect(identities.count == 3)
    }

    @Test("Import key bundle skips existing keys")
    func importKeyBundleSkipsExisting() async throws {
        let (manager, store, _) = try makeManager()

        let existingKeys = try KeychainIdentityKeys.generate()
        _ = try await store.save(inboxId: "inbox-1", clientId: "client-1", keys: existingKeys)

        let newKeys = try KeychainIdentityKeys.generate()
        let bundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "", inboxId: "inbox-1", clientId: "client-1", privateKeyData: Data(newKeys.privateKey.secp256K1.bytes), databaseKey: newKeys.databaseKey),
                DeviceKeyEntry(conversationId: "", inboxId: "inbox-2", clientId: "client-2", privateKeyData: Data(newKeys.privateKey.secp256K1.bytes), databaseKey: newKeys.databaseKey),
            ],
            senderInstallationId: "install-1"
        )

        await manager.vaultClient(VaultClient(), didReceiveKeyBundle: bundle, from: "other-inbox")

        try await Task.sleep(for: .milliseconds(100))

        let identities = try await store.loadAll()
        #expect(identities.count == 2)

        let inbox1 = identities.first { $0.inboxId == "inbox-1" }
        #expect(inbox1?.keys.databaseKey == existingKeys.databaseKey)
    }

    @Test("VaultDevice model")
    func vaultDeviceModel() {
        let device = VaultDevice(inboxId: "inbox-123", name: "My iPhone", isCurrentDevice: true)
        #expect(device.inboxId == "inbox-123")
        #expect(device.name == "My iPhone")
        #expect(device.isCurrentDevice == true)
    }

    @Test("Not connected throws on shareAllKeys")
    func notConnectedThrowsShareAll() async throws {
        let (manager, _, _) = try makeManager()

        await #expect(throws: VaultClientError.self) {
            try await manager.shareAllKeys()
        }
    }

    @Test("Bootstrap state starts as notStarted")
    func bootstrapStateInitial() async throws {
        let (manager, _, _) = try makeManager()
        let state = await manager.bootstrapState
        #expect(state == .notStarted)
    }

    @Test("Has multiple devices returns false when empty")
    func hasMultipleDevicesEmpty() async throws {
        let (manager, _, _) = try makeManager()
        let result = await manager.hasMultipleDevices
        #expect(result == false)
    }

    @Test("List devices returns self when DB has vault table but no rows")
    func listDevicesFallback() async throws {
        let store = MockKeychainIdentityStore()
        let dbQueue = try DatabaseQueue()
        try await dbQueue.write { db in
            try db.create(table: "vaultDevice") { table in
                table.column("inboxId", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("isCurrentDevice", .boolean).notNull()
                table.column("addedAt", .datetime).notNull()
            }
        }
        let manager = VaultManager(identityStore: store, databaseReader: dbQueue, deviceName: "Test iPhone")
        let devices = try await manager.listDevices()
        #expect(devices.count == 1)
        #expect(devices[0].name == "Test iPhone")
        #expect(devices[0].isCurrentDevice == true)
    }
}
