@testable import ConvosCore
import Foundation
import Testing

@Suite("VaultKeyStore Tests")
struct VaultKeyStoreTests {
    @Test("Save stores to both local and iCloud")
    func saveToBoth() async throws {
        let local = MockKeychainKeyStore()
        let icloud = MockKeychainKeyStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        try await vaultKeyStore.save(keys: keys)

        #expect(try await local.exists(identifier: "vault") == true)
        #expect(try await icloud.exists(identifier: "vault") == true)

        #expect(await local.accessibility(for: "vault") == .afterFirstUnlockThisDeviceOnly)
        #expect(await icloud.accessibility(for: "vault") == .afterFirstUnlock)
    }

    @Test("Load prefers local keychain")
    func loadPrefersLocal() async throws {
        let local = MockKeychainKeyStore()
        let icloud = MockKeychainKeyStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let localKeys = try KeychainIdentityKeys.generate()
        let icloudKeys = try KeychainIdentityKeys.generate()

        try await local.save(keys: localKeys, identifier: "vault", accessibility: .afterFirstUnlockThisDeviceOnly)
        try await icloud.save(keys: icloudKeys, identifier: "vault", accessibility: .afterFirstUnlock)

        let loaded = try await vaultKeyStore.load()
        #expect(loaded.privateKey.secp256K1.bytes == localKeys.privateKey.secp256K1.bytes)
    }

    @Test("Load falls back to iCloud when local missing")
    func loadFallbackToICloud() async throws {
        let local = MockKeychainKeyStore()
        let icloud = MockKeychainKeyStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let icloudKeys = try KeychainIdentityKeys.generate()
        try await icloud.save(keys: icloudKeys, identifier: "vault", accessibility: .afterFirstUnlock)

        let loaded = try await vaultKeyStore.load()
        #expect(loaded.privateKey.secp256K1.bytes == icloudKeys.privateKey.secp256K1.bytes)
    }

    @Test("Load from iCloud also caches to local")
    func loadFromICloudCachesLocally() async throws {
        let local = MockKeychainKeyStore()
        let icloud = MockKeychainKeyStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let icloudKeys = try KeychainIdentityKeys.generate()
        try await icloud.save(keys: icloudKeys, identifier: "vault", accessibility: .afterFirstUnlock)

        _ = try await vaultKeyStore.load()

        #expect(try await local.exists(identifier: "vault") == true)
        let cached = try await local.load(identifier: "vault")
        #expect(cached.privateKey.secp256K1.bytes == icloudKeys.privateKey.secp256K1.bytes)
    }

    @Test("Load throws when neither store has key")
    func loadThrowsWhenEmpty() async {
        let local = MockKeychainKeyStore()
        let icloud = MockKeychainKeyStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        await #expect(throws: KeychainIdentityStoreError.self) {
            _ = try await vaultKeyStore.load()
        }
    }

    @Test("Exists returns true when local has key")
    func existsLocal() async throws {
        let local = MockKeychainKeyStore()
        let icloud = MockKeychainKeyStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        try await local.save(keys: keys, identifier: "vault", accessibility: .afterFirstUnlockThisDeviceOnly)

        #expect(await vaultKeyStore.exists() == true)
    }

    @Test("Exists returns true when only iCloud has key")
    func existsICloud() async throws {
        let local = MockKeychainKeyStore()
        let icloud = MockKeychainKeyStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        try await icloud.save(keys: keys, identifier: "vault", accessibility: .afterFirstUnlock)

        #expect(await vaultKeyStore.exists() == true)
    }

    @Test("Exists returns false when neither has key")
    func existsFalse() async throws {
        let local = MockKeychainKeyStore()
        let icloud = MockKeychainKeyStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        #expect(await vaultKeyStore.exists() == false)
    }

    @Test("Delete removes from both stores")
    func deleteBoth() async throws {
        let local = MockKeychainKeyStore()
        let icloud = MockKeychainKeyStore()
        let vaultKeyStore = VaultKeyStore(localStore: local, icloudStore: icloud)

        let keys = try KeychainIdentityKeys.generate()
        try await vaultKeyStore.save(keys: keys)

        try await vaultKeyStore.delete()

        #expect(try await local.exists(identifier: "vault") == false)
        #expect(try await icloud.exists(identifier: "vault") == false)
    }
}
