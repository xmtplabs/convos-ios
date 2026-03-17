@testable import ConvosCore
import Foundation
import Testing

@Suite("VaultKeyStore Tests")
struct VaultKeyStoreTests {
    let vaultInboxId: String = "abc123-vault-inbox"
    let vaultClientId: String = "vault-client-1"

    @Test("Save and load by inboxId")
    func saveAndLoad() async throws {
        let mock = MockKeychainIdentityStore()
        let store = VaultKeyStore(store: mock)

        let keys = try KeychainIdentityKeys.generate()
        try await store.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        let loaded = try await store.load(inboxId: vaultInboxId)
        #expect(loaded.inboxId == vaultInboxId)
        #expect(loaded.clientId == vaultClientId)
        #expect(loaded.keys.privateKey.secp256K1.bytes == keys.privateKey.secp256K1.bytes)
    }

    @Test("Load throws when not found")
    func loadThrows() async {
        let mock = MockKeychainIdentityStore()
        let store = VaultKeyStore(store: mock)

        await #expect(throws: KeychainIdentityStoreError.self) {
            _ = try await store.load(inboxId: "nonexistent")
        }
    }

    @Test("loadAny finds the vault identity")
    func loadAny() async throws {
        let mock = MockKeychainIdentityStore()
        let store = VaultKeyStore(store: mock)

        let keys = try KeychainIdentityKeys.generate()
        try await store.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        let loaded = try await store.loadAny()
        #expect(loaded.inboxId == vaultInboxId)
    }

    @Test("loadAny throws when empty")
    func loadAnyThrows() async {
        let mock = MockKeychainIdentityStore()
        let store = VaultKeyStore(store: mock)

        await #expect(throws: KeychainIdentityStoreError.self) {
            _ = try await store.loadAny()
        }
    }

    @Test("Exists returns true when key present")
    func existsTrue() async throws {
        let mock = MockKeychainIdentityStore()
        let store = VaultKeyStore(store: mock)

        let keys = try KeychainIdentityKeys.generate()
        try await store.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        #expect(await store.exists() == true)
    }

    @Test("Exists returns false when empty")
    func existsFalse() async {
        let mock = MockKeychainIdentityStore()
        let store = VaultKeyStore(store: mock)

        #expect(await store.exists() == false)
    }

    @Test("Delete removes the key")
    func delete() async throws {
        let mock = MockKeychainIdentityStore()
        let store = VaultKeyStore(store: mock)

        let keys = try KeychainIdentityKeys.generate()
        try await store.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        try await store.delete(inboxId: vaultInboxId)
        #expect(await store.exists() == false)
    }

    @Test("Delete local preserves iCloud vault key copy")
    func deleteLocalPreservesICloudCopy() async throws {
        let localStore = MockKeychainIdentityStore()
        let iCloudStore = MockKeychainIdentityStore()
        let dualStore = ICloudIdentityStore(localStore: localStore, icloudStore: iCloudStore)
        let store = VaultKeyStore(store: dualStore)

        let keys = try KeychainIdentityKeys.generate()
        try await store.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        try await store.deleteLocal(inboxId: vaultInboxId)

        await #expect(throws: KeychainIdentityStoreError.self) {
            _ = try await localStore.identity(for: self.vaultInboxId)
        }

        let iCloudIdentity = try await iCloudStore.identity(for: vaultInboxId)
        #expect(iCloudIdentity.inboxId == vaultInboxId)

        let reloaded = try await store.loadAny()
        #expect(reloaded.keys.databaseKey == keys.databaseKey)
    }

    @Test("Delete removes both local and iCloud vault key copies")
    func deleteRemovesBothCopies() async throws {
        let localStore = MockKeychainIdentityStore()
        let iCloudStore = MockKeychainIdentityStore()
        let dualStore = ICloudIdentityStore(localStore: localStore, icloudStore: iCloudStore)
        let store = VaultKeyStore(store: dualStore)

        let keys = try KeychainIdentityKeys.generate()
        try await store.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        try await store.delete(inboxId: vaultInboxId)

        await #expect(throws: KeychainIdentityStoreError.self) {
            _ = try await localStore.identity(for: self.vaultInboxId)
        }
        await #expect(throws: KeychainIdentityStoreError.self) {
            _ = try await iCloudStore.identity(for: self.vaultInboxId)
        }
    }

    @Test("DeleteAll clears everything")
    func deleteAll() async throws {
        let mock = MockKeychainIdentityStore()
        let store = VaultKeyStore(store: mock)

        let keys1 = try KeychainIdentityKeys.generate()
        let keys2 = try KeychainIdentityKeys.generate()
        try await store.save(inboxId: "inbox-1", clientId: "client-1", keys: keys1)
        try await store.save(inboxId: "inbox-2", clientId: "client-2", keys: keys2)

        try await store.deleteAll()
        #expect(await store.exists() == false)
    }
}
