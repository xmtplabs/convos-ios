@testable import ConvosCore
import Foundation
import Testing
import XMTPiOS

actor MockVaultIdentityStore: VaultIdentityStoreProtocol {
    private var entries: [String: VaultIdentityEntry] = [:]

    func generateKeys() throws -> VaultIdentityKeys {
        VaultIdentityKeys(
            privateKeyData: Data(repeating: 0xAA, count: 32),
            databaseKey: Data(repeating: 0xBB, count: 32)
        )
    }

    func allIdentities() throws -> [VaultIdentityEntry] {
        Array(entries.values)
    }

    func save(entry: VaultIdentityEntry) throws {
        entries[entry.inboxId] = entry
    }

    func hasIdentity(for inboxId: String) -> Bool {
        entries[inboxId] != nil
    }

    func reset() {
        entries.removeAll()
    }
}

@Suite("VaultManager Tests")
struct VaultManagerTests {
    @Test("Import key share saves to identity store")
    func importKeyShare() async throws {
        let store = MockVaultIdentityStore()
        let manager = VaultManager(identityStore: store, deviceName: "Test iPhone")

        let share = DeviceKeyShareContent(
            conversationId: "conv-1",
            inboxId: "inbox-1",
            clientId: "client-1",
            privateKeyData: Data([1, 2, 3]),
            databaseKey: Data([4, 5, 6]),
            senderInstallationId: "install-1"
        )

        manager.vaultClient(VaultClient(), didReceiveKeyShare: share, from: "other-inbox")

        try await Task.sleep(for: .milliseconds(50))

        let identities = try await store.allIdentities()
        #expect(identities.count == 1)
        #expect(identities[0].conversationId == "conv-1")
        #expect(identities[0].inboxId == "inbox-1")
        #expect(identities[0].privateKeyData == Data([1, 2, 3]))
    }

    @Test("Import key share skips duplicates")
    func importKeyShareSkipsDuplicates() async throws {
        let store = MockVaultIdentityStore()
        let manager = VaultManager(identityStore: store, deviceName: "Test iPhone")

        let entry = VaultIdentityEntry(
            conversationId: "conv-1",
            inboxId: "inbox-1",
            clientId: "client-1",
            privateKeyData: Data([1, 2, 3]),
            databaseKey: Data([4, 5, 6])
        )
        try await store.save(entry: entry)

        let share = DeviceKeyShareContent(
            conversationId: "conv-1",
            inboxId: "inbox-1",
            clientId: "client-1",
            privateKeyData: Data([7, 8, 9]),
            databaseKey: Data([10, 11, 12]),
            senderInstallationId: "install-1"
        )

        manager.vaultClient(VaultClient(), didReceiveKeyShare: share, from: "other-inbox")

        try await Task.sleep(for: .milliseconds(50))

        let identities = try await store.allIdentities()
        #expect(identities.count == 1)
        #expect(identities[0].privateKeyData == Data([1, 2, 3]))
    }

    @Test("Import key bundle saves multiple keys")
    func importKeyBundle() async throws {
        let store = MockVaultIdentityStore()
        let manager = VaultManager(identityStore: store, deviceName: "Test iPhone")

        let bundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-1", inboxId: "inbox-1", clientId: "client-1", privateKeyData: Data([1]), databaseKey: Data([2])),
                DeviceKeyEntry(conversationId: "conv-2", inboxId: "inbox-2", clientId: "client-2", privateKeyData: Data([3]), databaseKey: Data([4])),
                DeviceKeyEntry(conversationId: "conv-3", inboxId: "inbox-3", clientId: "client-3", privateKeyData: Data([5]), databaseKey: Data([6])),
            ],
            senderInstallationId: "install-1"
        )

        manager.vaultClient(VaultClient(), didReceiveKeyBundle: bundle, from: "other-inbox")

        try await Task.sleep(for: .milliseconds(100))

        let identities = try await store.allIdentities()
        #expect(identities.count == 3)
    }

    @Test("Import key bundle skips existing keys")
    func importKeyBundleSkipsExisting() async throws {
        let store = MockVaultIdentityStore()
        let manager = VaultManager(identityStore: store, deviceName: "Test iPhone")

        let existing = VaultIdentityEntry(
            conversationId: "conv-1",
            inboxId: "inbox-1",
            clientId: "client-1",
            privateKeyData: Data([99]),
            databaseKey: Data([99])
        )
        try await store.save(entry: existing)

        let bundle = DeviceKeyBundleContent(
            keys: [
                DeviceKeyEntry(conversationId: "conv-1", inboxId: "inbox-1", clientId: "client-1", privateKeyData: Data([1]), databaseKey: Data([2])),
                DeviceKeyEntry(conversationId: "conv-2", inboxId: "inbox-2", clientId: "client-2", privateKeyData: Data([3]), databaseKey: Data([4])),
            ],
            senderInstallationId: "install-1"
        )

        manager.vaultClient(VaultClient(), didReceiveKeyBundle: bundle, from: "other-inbox")

        try await Task.sleep(for: .milliseconds(100))

        let identities = try await store.allIdentities()
        #expect(identities.count == 2)

        let inbox1 = identities.first { $0.inboxId == "inbox-1" }
        #expect(inbox1?.privateKeyData == Data([99]))
    }

    @Test("VaultDevice model")
    func vaultDeviceModel() {
        let device = VaultDevice(inboxId: "inbox-123", name: "My iPhone", isCurrentDevice: true)
        #expect(device.inboxId == "inbox-123")
        #expect(device.name == "My iPhone")
        #expect(device.isCurrentDevice == true)
    }

    @Test("VaultIdentityEntry model")
    func vaultIdentityEntryModel() {
        let entry = VaultIdentityEntry(
            conversationId: "conv-1",
            inboxId: "inbox-1",
            clientId: "client-1",
            privateKeyData: Data([1, 2, 3]),
            databaseKey: Data([4, 5, 6])
        )
        #expect(entry.conversationId == "conv-1")
        #expect(entry.inboxId == "inbox-1")
        #expect(entry.clientId == "client-1")
    }

    @Test("Not connected throws on share")
    func notConnectedThrows() async {
        let store = MockVaultIdentityStore()
        let manager = VaultManager(identityStore: store, deviceName: "Test iPhone")

        let entry = VaultIdentityEntry(
            conversationId: "conv-1",
            inboxId: "inbox-1",
            clientId: "client-1",
            privateKeyData: Data([1]),
            databaseKey: Data([2])
        )

        await #expect(throws: VaultClientError.self) {
            try await manager.shareKey(entry)
        }
    }

    @Test("Not connected throws on shareAllKeys")
    func notConnectedThrowsShareAll() async {
        let store = MockVaultIdentityStore()
        let manager = VaultManager(identityStore: store, deviceName: "Test iPhone")

        await #expect(throws: VaultClientError.self) {
            try await manager.shareAllKeys()
        }
    }
}
