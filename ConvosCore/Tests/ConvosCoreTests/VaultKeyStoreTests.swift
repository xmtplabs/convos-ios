@testable import ConvosCore
import Foundation
import Testing

@Suite("VaultKeyStore Tests")
struct VaultKeyStoreTests {
    let vaultInboxId: String = "abc123-vault-inbox"
    let vaultClientId: String = "vault-client-1"

    @Test("Save stores to both local and iCloud")
    func saveToBoth() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        try await store.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        let localIdentities = try await local.loadAll()
        let icloudIdentities = try await icloud.loadAll()
        #expect(localIdentities.count == 1)
        #expect(icloudIdentities.count == 1)
        #expect(localIdentities[0].inboxId == vaultInboxId)
        #expect(localIdentities[0].clientId == vaultClientId)
    }

    @Test("Load prefers local keychain")
    func loadPrefersLocal() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        let localKeys = try KeychainIdentityKeys.generate()
        let icloudKeys = try KeychainIdentityKeys.generate()

        _ = try await local.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: localKeys)
        _ = try await icloud.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: icloudKeys)

        let loaded = try await store.load(inboxId: vaultInboxId)
        #expect(loaded.keys.privateKey.secp256K1.bytes == localKeys.privateKey.secp256K1.bytes)
    }

    @Test("Load falls back to iCloud when local missing")
    func loadFallbackToICloud() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        let icloudKeys = try KeychainIdentityKeys.generate()
        _ = try await icloud.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: icloudKeys)

        let loaded = try await store.load(inboxId: vaultInboxId)
        #expect(loaded.keys.privateKey.secp256K1.bytes == icloudKeys.privateKey.secp256K1.bytes)
        #expect(loaded.clientId == vaultClientId)
    }

    @Test("Load from iCloud caches to local")
    func loadFromICloudCachesLocally() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        let icloudKeys = try KeychainIdentityKeys.generate()
        _ = try await icloud.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: icloudKeys)

        _ = try await store.load(inboxId: vaultInboxId)

        let localIdentities = try await local.loadAll()
        #expect(localIdentities.count == 1)
        #expect(localIdentities[0].keys.privateKey.secp256K1.bytes == icloudKeys.privateKey.secp256K1.bytes)
    }

    @Test("Load throws when neither store has key")
    func loadThrowsWhenEmpty() async {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        await #expect(throws: KeychainIdentityStoreError.self) {
            _ = try await store.load(inboxId: vaultInboxId)
        }
    }

    @Test("loadFromAnyStore finds local identity")
    func loadFromAnyStoreLocal() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        _ = try await local.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        let loaded = try await store.loadFromAnyStore()
        #expect(loaded.inboxId == vaultInboxId)
        #expect(loaded.clientId == vaultClientId)
    }

    @Test("loadFromAnyStore falls back to iCloud")
    func loadFromAnyStoreICloud() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        _ = try await icloud.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        let loaded = try await store.loadFromAnyStore()
        #expect(loaded.inboxId == vaultInboxId)

        let localIdentities = try await local.loadAll()
        #expect(localIdentities.count == 1)
    }

    @Test("loadFromAnyStore throws when empty")
    func loadFromAnyStoreThrows() async {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        await #expect(throws: KeychainIdentityStoreError.self) {
            _ = try await store.loadFromAnyStore()
        }
    }

    @Test("Exists returns true when local has key")
    func existsLocal() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        _ = try await local.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        #expect(await store.exists() == true)
    }

    @Test("Exists returns true when only iCloud has key")
    func existsICloud() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        _ = try await icloud.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        #expect(await store.exists() == true)
    }

    @Test("Exists returns false when neither has key")
    func existsFalse() async {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        #expect(await store.exists() == false)
    }

    @Test("Delete removes from both stores")
    func deleteBoth() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        try await store.save(inboxId: vaultInboxId, clientId: vaultClientId, keys: keys)

        try await store.delete(inboxId: vaultInboxId)

        let localIdentities = try await local.loadAll()
        let icloudIdentities = try await icloud.loadAll()
        #expect(localIdentities.isEmpty)
        #expect(icloudIdentities.isEmpty)
    }

    @Test("DeleteAll removes everything from both stores")
    func deleteAll() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let store = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys1 = try KeychainIdentityKeys.generate()
        let keys2 = try KeychainIdentityKeys.generate()
        try await store.save(inboxId: "inbox-1", clientId: "client-1", keys: keys1)
        try await store.save(inboxId: "inbox-2", clientId: "client-2", keys: keys2)

        try await store.deleteAll()

        #expect(await store.exists() == false)
    }
}
