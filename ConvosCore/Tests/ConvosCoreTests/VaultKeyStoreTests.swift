@testable import ConvosCore
import Foundation
import Testing

@Suite("VaultKeyStore Tests")
struct VaultKeyStoreTests {
    @Test("Save stores to both local and iCloud")
    func saveToBoth() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        try await vaultKeyStore.save(keys: keys)

        let localIdentities = try await local.loadAll()
        let icloudIdentities = try await icloud.loadAll()
        #expect(localIdentities.count == 1)
        #expect(icloudIdentities.count == 1)
        #expect(localIdentities[0].inboxId == "vault")
        #expect(icloudIdentities[0].inboxId == "vault")
    }

    @Test("Load prefers local keychain")
    func loadPrefersLocal() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let localKeys = try KeychainIdentityKeys.generate()
        let icloudKeys = try KeychainIdentityKeys.generate()

        _ = try await local.save(inboxId: "vault", clientId: "vault", keys: localKeys)
        _ = try await icloud.save(inboxId: "vault", clientId: "vault", keys: icloudKeys)

        let loaded = try await vaultKeyStore.load()
        #expect(loaded.privateKey.secp256K1.bytes == localKeys.privateKey.secp256K1.bytes)
    }

    @Test("Load falls back to iCloud when local missing")
    func loadFallbackToICloud() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let icloudKeys = try KeychainIdentityKeys.generate()
        _ = try await icloud.save(inboxId: "vault", clientId: "vault", keys: icloudKeys)

        let loaded = try await vaultKeyStore.load()
        #expect(loaded.privateKey.secp256K1.bytes == icloudKeys.privateKey.secp256K1.bytes)
    }

    @Test("Load from iCloud also caches to local")
    func loadFromICloudCachesLocally() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let icloudKeys = try KeychainIdentityKeys.generate()
        _ = try await icloud.save(inboxId: "vault", clientId: "vault", keys: icloudKeys)

        _ = try await vaultKeyStore.load()

        let localIdentities = try await local.loadAll()
        #expect(localIdentities.count == 1)
        let cached = localIdentities[0]
        #expect(cached.keys.privateKey.secp256K1.bytes == icloudKeys.privateKey.secp256K1.bytes)
    }

    @Test("Load throws when neither store has key")
    func loadThrowsWhenEmpty() async {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        await #expect(throws: KeychainIdentityStoreError.self) {
            _ = try await vaultKeyStore.load()
        }
    }

    @Test("Exists returns true when local has key")
    func existsLocal() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        _ = try await local.save(inboxId: "vault", clientId: "vault", keys: keys)

        let result = await vaultKeyStore.exists()
        #expect(result == true)
    }

    @Test("Exists returns true when only iCloud has key")
    func existsICloud() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        _ = try await icloud.save(inboxId: "vault", clientId: "vault", keys: keys)

        let result = await vaultKeyStore.exists()
        #expect(result == true)
    }

    @Test("Exists returns false when neither has key")
    func existsFalse() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let result = await vaultKeyStore.exists()
        #expect(result == false)
    }

    @Test("Delete removes from both stores")
    func deleteBoth() async throws {
        let local = MockKeychainIdentityStore()
        let icloud = MockKeychainIdentityStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        try await vaultKeyStore.save(keys: keys)

        try await vaultKeyStore.delete()

        let localIdentities = try await local.loadAll()
        let icloudIdentities = try await icloud.loadAll()
        #expect(localIdentities.isEmpty)
        #expect(icloudIdentities.isEmpty)
    }
}
