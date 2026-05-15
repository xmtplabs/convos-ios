import ConvosCore
import Foundation
import Security
import Testing

/// Integration tests for KeychainIdentityStore against a real keychain.
///
/// Runs in a dedicated target with the entitlements required to access the
/// shared access group. Unit-level coverage of the store contract (on the
/// mock) lives in `ConvosCoreTests/KeychainSyncConfigTests.swift`.
@Suite(.serialized) class KeychainIdentityStoreRealKeychainTests {
    private let keychainStore: KeychainIdentityStore
    private let testAccessGroup: String = "FY4NZR34Z3.org.convos.KeychainIdentityStoreExample"

    init() throws {
        keychainStore = KeychainIdentityStore(accessGroup: testAccessGroup)
    }

    @Test func generatesKeys() async throws {
        let keys = try await keychainStore.generateKeys()
        #expect(keys.databaseKey.count == 32)
    }

    @Test func savesAndLoadsIdentity() async throws {
        try await keychainStore.delete()

        let keys = try await keychainStore.generateKeys()
        let saved = try await keychainStore.save(
            inboxId: "test-inbox-123",
            clientId: "test-client-123",
            keys: keys
        )

        #expect(saved.inboxId == "test-inbox-123")
        #expect(saved.clientId == "test-client-123")
        #expect(saved.keys.databaseKey == keys.databaseKey)

        let loaded = try await keychainStore.load()
        #expect(loaded?.inboxId == "test-inbox-123")
        #expect(loaded?.clientId == "test-client-123")
        #expect(loaded?.keys.databaseKey == keys.databaseKey)
    }

    @Test func loadReturnsNilWhenEmpty() async throws {
        try await keychainStore.delete()

        let loaded = try await keychainStore.load()
        #expect(loaded == nil)
    }

    @Test func saveOverwritesExistingIdentity() async throws {
        try await keychainStore.delete()

        let firstKeys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(inboxId: "first", clientId: "first-client", keys: firstKeys)

        let secondKeys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(inboxId: "second", clientId: "second-client", keys: secondKeys)

        let loaded = try await keychainStore.load()
        #expect(loaded?.inboxId == "second")
        #expect(loaded?.clientId == "second-client")
        #expect(loaded?.keys.databaseKey == secondKeys.databaseKey)
    }

    @Test func deleteIsIdempotent() async throws {
        try await keychainStore.delete()
        try await keychainStore.delete()

        let loaded = try await keychainStore.load()
        #expect(loaded == nil)
    }

    @Test func deleteClearsStoredIdentity() async throws {
        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(inboxId: "delete-me", clientId: "delete-me-client", keys: keys)
        #expect(try await keychainStore.load() != nil)

        try await keychainStore.delete()
        #expect(try await keychainStore.load() == nil)
    }

    @Test func preservesLongIdentifiers() async throws {
        try await keychainStore.delete()

        let longInboxId = String(repeating: "a", count: 1000)
        let longClientId = String(repeating: "b", count: 1000)
        let keys = try await keychainStore.generateKeys()

        _ = try await keychainStore.save(inboxId: longInboxId, clientId: longClientId, keys: keys)
        let loaded = try await keychainStore.load()

        #expect(loaded?.inboxId == longInboxId)
        #expect(loaded?.clientId == longClientId)
        #expect(loaded?.keys.databaseKey == keys.databaseKey)
    }

    @Test func preservesSpecialCharacters() async throws {
        try await keychainStore.delete()

        let inboxId = "test-inbox!@#$%^&*()_+-=[]{}|;':\",./<>?"
        let clientId = "test-client!@#$%^&*()_+-=[]{}|;':\",./<>?"
        let keys = try await keychainStore.generateKeys()

        _ = try await keychainStore.save(inboxId: inboxId, clientId: clientId, keys: keys)
        let loaded = try await keychainStore.load()

        #expect(loaded?.inboxId == inboxId)
        #expect(loaded?.clientId == clientId)
        #expect(loaded?.keys.databaseKey == keys.databaseKey)
    }

    @Test func preservesUnicode() async throws {
        try await keychainStore.delete()

        let inboxId = "inbox-🚀-🎉-🌟"
        let clientId = "client-🚀-🎉-🌟"
        let keys = try await keychainStore.generateKeys()

        _ = try await keychainStore.save(inboxId: inboxId, clientId: clientId, keys: keys)
        let loaded = try await keychainStore.load()

        #expect(loaded?.inboxId == inboxId)
        #expect(loaded?.clientId == clientId)
    }

    @Test func encodesKeysRoundTrip() async throws {
        let keys = try await keychainStore.generateKeys()
        let encoded = try JSONEncoder().encode(keys)
        let decoded = try JSONDecoder().decode(KeychainIdentityKeys.self, from: encoded)
        #expect(decoded.databaseKey == keys.databaseKey)
    }

    /// `KeychainIdentityStore` now writes with
    /// `kSecAttrSynchronizable: true` to the new `syncedIdentityService`
    /// slot so the identity propagates via iCloud Keychain to every
    /// device on the same Apple ID. The legacy
    /// `kSecAttrSynchronizable: false` slot at the v3 service is
    /// retained as a read-only migration source — new writes must
    /// never land there.
    @Test func savedIdentityIsSyncedNotLocal() async throws {
        try await keychainStore.delete()

        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "sync-check-inbox",
            clientId: "sync-check-client",
            keys: keys
        )

        // Synced slot at the v4-synced service → must find the item.
        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.syncedIdentityService,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrSynchronizable as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var syncResult: CFTypeRef?
        let syncStatus = SecItemCopyMatching(syncQuery as CFDictionary, &syncResult)
        #expect(syncStatus == errSecSuccess, "Item should be present in the synced slot (status=\(syncStatus))")

        // Legacy v3 service must NOT receive new writes.
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.legacyIdentityService,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var legacyResult: CFTypeRef?
        let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult)
        #expect(legacyStatus == errSecItemNotFound, "Item must not be in the legacy slot (status=\(legacyStatus))")
    }

    /// Existing users on the pre-sync build have their identity in the
    /// legacy device-local slot. The first `load()` on the new build
    /// must return that identity *and* migrate it to the synced slot
    /// so subsequent loads stay on the synced path.
    @Test func legacyIdentityMigratesToSyncedOnLoad() async throws {
        try await keychainStore.delete()

        let keys = try await keychainStore.generateKeys()
        let identity = KeychainIdentity(
            inboxId: "legacy-inbox",
            clientId: "legacy-client",
            keys: keys
        )
        let data = try JSONEncoder().encode(identity)

        // Seed the legacy slot directly (bypass the store's save path,
        // which would route to the synced slot).
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.legacyIdentityService,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        _ = SecItemDelete(addQuery as CFDictionary) // clean any stale entry
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        #expect(addStatus == errSecSuccess, "Failed to seed legacy slot: \(addStatus)")

        // load() must return the seeded identity (verifies legacy fallback).
        let loaded = try await keychainStore.load()
        #expect(loaded?.inboxId == "legacy-inbox")
        #expect(loaded?.clientId == "legacy-client")
        #expect(loaded?.keys.databaseKey == keys.databaseKey)

        // After load(), the identity must have moved to the synced slot.
        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.syncedIdentityService,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrSynchronizable as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var syncResult: CFTypeRef?
        let syncStatus = SecItemCopyMatching(syncQuery as CFDictionary, &syncResult)
        #expect(syncStatus == errSecSuccess, "Identity should have migrated to the synced slot")

        // …and the legacy slot must be empty.
        let legacyCheck: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.legacyIdentityService,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var legacyResult: CFTypeRef?
        let legacyStatus = SecItemCopyMatching(legacyCheck as CFDictionary, &legacyResult)
        #expect(legacyStatus == errSecItemNotFound, "Legacy slot must be cleared post-migration")
    }

    /// `currentStorageLocation()` is the debug-UI signal for "is this
    /// device on the new synced layout yet". Three states.
    @Test func currentStorageLocationReportsTheActiveSlot() async throws {
        try await keychainStore.delete()
        #expect(keychainStore.currentStorageLocation() == .missing)

        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "loc-inbox",
            clientId: "loc-client",
            keys: keys
        )
        #expect(keychainStore.currentStorageLocation() == .synced)
    }

    @Test func encodesIdentityRoundTrip() async throws {
        try await keychainStore.delete()

        let keys = try await keychainStore.generateKeys()
        let saved = try await keychainStore.save(
            inboxId: "coding-inbox",
            clientId: "coding-client",
            keys: keys
        )

        let encoded = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(KeychainIdentity.self, from: encoded)

        #expect(decoded.inboxId == saved.inboxId)
        #expect(decoded.clientId == saved.clientId)
        #expect(decoded.keys.databaseKey == saved.keys.databaseKey)
    }
}
