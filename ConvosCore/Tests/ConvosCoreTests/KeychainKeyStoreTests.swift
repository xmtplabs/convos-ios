@testable import ConvosCore
import Foundation
import Testing

@Suite("KeychainKeyStore Tests")
struct KeychainKeyStoreTests {
    let store: MockKeychainKeyStore = MockKeychainKeyStore()

    @Test("Save and load keys")
    func saveAndLoad() async throws {
        let keys = try KeychainIdentityKeys.generate()
        try await store.save(keys: keys, identifier: "vault-key", accessibility: .afterFirstUnlockThisDeviceOnly)

        let loaded = try await store.load(identifier: "vault-key")
        #expect(loaded.privateKey.secp256K1.bytes == keys.privateKey.secp256K1.bytes)
        #expect(loaded.databaseKey == keys.databaseKey)
    }

    @Test("Load nonexistent key throws")
    func loadNonexistent() async {
        await #expect(throws: KeychainIdentityStoreError.self) {
            _ = try await store.load(identifier: "nonexistent")
        }
    }

    @Test("Exists returns true for saved key")
    func existsTrue() async throws {
        let keys = try KeychainIdentityKeys.generate()
        try await store.save(keys: keys, identifier: "test-key", accessibility: .afterFirstUnlock)

        let result = try await store.exists(identifier: "test-key")
        #expect(result == true)
    }

    @Test("Exists returns false for missing key")
    func existsFalse() async throws {
        let result = try await store.exists(identifier: "missing-key")
        #expect(result == false)
    }

    @Test("Delete removes key")
    func deleteKey() async throws {
        let keys = try KeychainIdentityKeys.generate()
        try await store.save(keys: keys, identifier: "to-delete", accessibility: .afterFirstUnlockThisDeviceOnly)
        #expect(try await store.exists(identifier: "to-delete") == true)

        try await store.delete(identifier: "to-delete")
        #expect(try await store.exists(identifier: "to-delete") == false)
    }

    @Test("Delete nonexistent key does not throw")
    func deleteNonexistent() async throws {
        try await store.delete(identifier: "never-existed")
    }

    @Test("Overwrite existing key")
    func overwrite() async throws {
        let keys1 = try KeychainIdentityKeys.generate()
        let keys2 = try KeychainIdentityKeys.generate()

        try await store.save(keys: keys1, identifier: "overwrite-key", accessibility: .afterFirstUnlockThisDeviceOnly)
        try await store.save(keys: keys2, identifier: "overwrite-key", accessibility: .afterFirstUnlock)

        let loaded = try await store.load(identifier: "overwrite-key")
        #expect(loaded.privateKey.secp256K1.bytes == keys2.privateKey.secp256K1.bytes)
        #expect(loaded.databaseKey == keys2.databaseKey)
    }

    @Test("Accessibility is preserved")
    func accessibilityPreserved() async throws {
        let keys = try KeychainIdentityKeys.generate()

        try await store.save(keys: keys, identifier: "local-key", accessibility: .afterFirstUnlockThisDeviceOnly)
        #expect(await store.accessibility(for: "local-key") == .afterFirstUnlockThisDeviceOnly)

        try await store.save(keys: keys, identifier: "icloud-key", accessibility: .afterFirstUnlock)
        #expect(await store.accessibility(for: "icloud-key") == .afterFirstUnlock)
    }

    @Test("Multiple keys stored independently")
    func multipleKeys() async throws {
        let keys1 = try KeychainIdentityKeys.generate()
        let keys2 = try KeychainIdentityKeys.generate()

        try await store.save(keys: keys1, identifier: "key-a", accessibility: .afterFirstUnlockThisDeviceOnly)
        try await store.save(keys: keys2, identifier: "key-b", accessibility: .afterFirstUnlock)

        let loadedA = try await store.load(identifier: "key-a")
        let loadedB = try await store.load(identifier: "key-b")

        #expect(loadedA.privateKey.secp256K1.bytes == keys1.privateKey.secp256K1.bytes)
        #expect(loadedB.privateKey.secp256K1.bytes == keys2.privateKey.secp256K1.bytes)
    }

    @Test("Save with local accessibility uses ThisDeviceOnly")
    func localAccessibility() async throws {
        let keys = try KeychainIdentityKeys.generate()
        try await store.save(keys: keys, identifier: "device-only", accessibility: .afterFirstUnlockThisDeviceOnly)
        #expect(await store.accessibility(for: "device-only") == .afterFirstUnlockThisDeviceOnly)
    }

    @Test("Save with iCloud accessibility uses AfterFirstUnlock")
    func icloudAccessibility() async throws {
        let keys = try KeychainIdentityKeys.generate()
        try await store.save(keys: keys, identifier: "icloud-sync", accessibility: .afterFirstUnlock)
        #expect(await store.accessibility(for: "icloud-sync") == .afterFirstUnlock)
    }
}
