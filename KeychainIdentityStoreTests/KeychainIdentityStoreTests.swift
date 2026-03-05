import ConvosCore
import Foundation
import Security
import Testing

/// Test suite for KeychainIdentityStore
@Suite(.serialized) class KeychainIdentityStoreExampleTests {
    // MARK: - Test Properties

    private let keychainStore: KeychainIdentityStore
    private let testAccessGroup: String = "FY4NZR34Z3.org.convos.KeychainIdentityStoreExample"

    init() throws {
        keychainStore = KeychainIdentityStore(accessGroup: testAccessGroup)
    }

    // MARK: - Identity Management Tests

    @Test func testGenerateKeys() async throws {
        // When
        let keys = try await keychainStore.generateKeys()

        // Then
        #expect(keys.databaseKey.count == 32)
    }

    @Test func testSaveAndLoadIdentity() async throws {
        // Given
        let inboxId = "test-inbox-123"
        let clientId = "test-client-123"
        let keys = try await keychainStore.generateKeys()

        // When
        let savedIdentity = try await keychainStore.save(inboxId: inboxId, clientId: clientId, keys: keys)

        // Then
        #expect(savedIdentity.inboxId == inboxId)
        #expect(savedIdentity.clientId == clientId)
        #expect(savedIdentity.keys.databaseKey == keys.databaseKey)

        // Verify we can load the identity
        let loadedIdentity = try await keychainStore.identity(for: inboxId)
        #expect(loadedIdentity.inboxId == savedIdentity.inboxId)
        #expect(loadedIdentity.clientId == savedIdentity.clientId)
        #expect(loadedIdentity.keys.databaseKey == savedIdentity.keys.databaseKey)
    }

    @Test func testLoadNonExistentIdentity() async throws {
        // When & Then
        do {
            _ = try await keychainStore.identity(for: "non-existent-inbox")
            #expect(Bool(false), "Expected error when loading non-existent identity")
        } catch {
            #expect(error is KeychainIdentityStoreError)
        }
    }

    @Test func testLoadAllIdentities() async throws {
        try await keychainStore.deleteAll()

        // Given
        let keys1 = try await keychainStore.generateKeys()
        let keys2 = try await keychainStore.generateKeys()
        let keys3 = try await keychainStore.generateKeys()

        let identity1 = try await keychainStore.save(inboxId: "inbox1", clientId: "client1", keys: keys1)
        let identity2 = try await keychainStore.save(inboxId: "inbox2", clientId: "client2", keys: keys2)
        let identity3 = try await keychainStore.save(inboxId: "inbox3", clientId: "client3", keys: keys3)

        // When
        let allIdentities = try await keychainStore.loadAll()

        // Then
        #expect(allIdentities.count == 3)
        #expect(allIdentities.contains { $0.inboxId == identity1.inboxId })
        #expect(allIdentities.contains { $0.inboxId == identity2.inboxId })
        #expect(allIdentities.contains { $0.inboxId == identity3.inboxId })
    }

    @Test func testLoadAllIdentitiesWhenEmpty() async throws {
        try await keychainStore.deleteAll()

        // When
        let allIdentities = try await keychainStore.loadAll()

        // Then
        #expect(allIdentities.isEmpty)
    }

    @Test func testDeleteIdentity() async throws {
        try await keychainStore.deleteAll()

        // Given
        let inboxId = "test-inbox-to-delete"
        let clientId = "test-client-to-delete"
        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(inboxId: inboxId, clientId: clientId, keys: keys)
        #expect(try await keychainStore.identity(for: inboxId).inboxId == inboxId)

        // When
        try await keychainStore.delete(inboxId: inboxId)

        // Then
        do {
            _ = try await keychainStore.identity(for: inboxId)
            #expect(Bool(false), "Expected error when loading deleted identity")
        } catch {
            #expect(error is KeychainIdentityStoreError)
        }

        let allIdentities = try await keychainStore.loadAll()
        #expect(!allIdentities.contains { $0.inboxId == inboxId })
    }

    @Test func testDeleteByClientId() async throws {
        try await keychainStore.deleteAll()

        // Given
        let inboxId = "test-inbox-delete-by-client"
        let clientId = "test-client-delete-by-client"
        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(inboxId: inboxId, clientId: clientId, keys: keys)
        #expect(try await keychainStore.identity(for: inboxId).inboxId == inboxId)

        // When
        _ = try await keychainStore.delete(clientId: clientId)

        // Then
        do {
            _ = try await keychainStore.identity(for: inboxId)
            #expect(Bool(false), "Expected error when loading deleted identity")
        } catch {
            #expect(error is KeychainIdentityStoreError)
        }

        let allIdentities = try await keychainStore.loadAll()
        #expect(!allIdentities.contains { $0.clientId == clientId })
    }

    @Test func testDeleteNonExistentIdentity() async throws {
        try await keychainStore.deleteAll()

        // When & Then - should not throw
        try await keychainStore.delete(inboxId: "non-existent-inbox")
    }

    @Test func testDeleteByNonExistentClientId() async throws {
        try await keychainStore.deleteAll()

        // When & Then
        do {
            _ = try await keychainStore.delete(clientId: "non-existent-client")
            #expect(Bool(false), "Expected error when deleting non-existent clientId")
        } catch {
            #expect(error is KeychainIdentityStoreError)
        }
    }

    // MARK: - Concurrency Tests

    @Test func testConcurrentIdentityOperations() async throws {
        try await keychainStore.deleteAll()

        // Given
        let numberOfIdentities = 10
        let store = keychainStore

        // When
        let identities = try await withThrowingTaskGroup(of: KeychainIdentity.self) { group in
            for i in 0..<numberOfIdentities {
                group.addTask {
                    let keys = try await store.generateKeys()
                    return try await store.save(inboxId: "concurrent-inbox-\(i)", clientId: "concurrent-client-\(i)", keys: keys)
                }
            }

            var results: [KeychainIdentity] = []
            for try await identity in group {
                results.append(identity)
            }
            return results
        }

        // Then
        #expect(identities.count == numberOfIdentities)

        let inboxIds = Set(identities.map { $0.inboxId })
        #expect(inboxIds.count == numberOfIdentities)

        let loadedIdentities = try await keychainStore.loadAll()
        #expect(loadedIdentities.count >= numberOfIdentities)
    }

    // MARK: - Edge Cases Tests

    @Test func testVeryLongInboxId() async throws {
        try await keychainStore.deleteAll()

        // Given
        let longInboxId = String(repeating: "a", count: 1000)
        let longClientId = String(repeating: "b", count: 1000)
        let keys = try await keychainStore.generateKeys()

        // When
        _ = try await keychainStore.save(inboxId: longInboxId, clientId: longClientId, keys: keys)
        let loadedIdentity = try await keychainStore.identity(for: longInboxId)

        // Then
        #expect(loadedIdentity.inboxId == longInboxId)
        #expect(loadedIdentity.keys.databaseKey == keys.databaseKey)
    }

    @Test func testSpecialCharactersInInboxId() async throws {
        try await keychainStore.deleteAll()

        // Given
        let inboxIdWithSpecialChars = "test-inbox!@#$%^&*()_+-=[]{}|;':\",./<>?"
        let clientIdWithSpecialChars = "test-client!@#$%^&*()_+-=[]{}|;':\",./<>?"
        let keys = try await keychainStore.generateKeys()

        // When
        _ = try await keychainStore.save(inboxId: inboxIdWithSpecialChars, clientId: clientIdWithSpecialChars, keys: keys)
        let loadedIdentity = try await keychainStore.identity(for: inboxIdWithSpecialChars)

        // Then
        #expect(loadedIdentity.inboxId == inboxIdWithSpecialChars)
        #expect(loadedIdentity.keys.databaseKey == keys.databaseKey)
    }

    @Test func testUnicodeCharactersInInboxId() async throws {
        try await keychainStore.deleteAll()

        // Given
        let inboxIdWithUnicode = "inbox-🚀-🎉-🌟"
        let clientIdWithUnicode = "client-🚀-🎉-🌟"
        let keys = try await keychainStore.generateKeys()

        // When
        _ = try await keychainStore.save(inboxId: inboxIdWithUnicode, clientId: clientIdWithUnicode, keys: keys)
        let loadedIdentity = try await keychainStore.identity(for: inboxIdWithUnicode)

        // Then
        #expect(loadedIdentity.inboxId == inboxIdWithUnicode)
        #expect(loadedIdentity.keys.databaseKey == keys.databaseKey)
    }

    // MARK: - Cleanup Tests

    @Test func testDeleteAll() async throws {
        try await keychainStore.deleteAll()

        // Given
        let keys1 = try await keychainStore.generateKeys()
        let keys2 = try await keychainStore.generateKeys()

        _ = try await keychainStore.save(inboxId: "delete-all-inbox1", clientId: "delete-all-client1", keys: keys1)
        _ = try await keychainStore.save(inboxId: "delete-all-inbox2", clientId: "delete-all-client2", keys: keys2)
        #expect(try await keychainStore.loadAll().count == 2)

        // When
        try await keychainStore.deleteAll()

        // Then
        #expect(try await keychainStore.loadAll().isEmpty)
    }

    @Test func testDeleteAllWhenEmpty() async throws {
        try await keychainStore.deleteAll()
        #expect(try await keychainStore.loadAll().isEmpty)

        // When & Then - should not throw
        try await keychainStore.deleteAll()
        #expect(try await keychainStore.loadAll().isEmpty)
    }

    // MARK: - KeychainIdentityKeys Coding Tests

    @Test func testKeychainIdentityKeysCoding() async throws {
        // Given
        let keys = try await keychainStore.generateKeys()

        // When
        let encoded = try JSONEncoder().encode(keys)
        let decoded = try JSONDecoder().decode(KeychainIdentityKeys.self, from: encoded)

        // Then
        #expect(decoded.databaseKey == keys.databaseKey)
    }

    @Test func testKeychainIdentityCoding() async throws {
        try await keychainStore.deleteAll()

        // Given
        let keys = try await keychainStore.generateKeys()
        let identity = try await keychainStore.save(inboxId: "coding-test-inbox", clientId: "coding-test-client", keys: keys)

        // When
        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(KeychainIdentity.self, from: encoded)

        // Then
        #expect(decoded.inboxId == identity.inboxId)
        #expect(decoded.keys.databaseKey == identity.keys.databaseKey)
    }

    // MARK: - Local Format Migration Tests (SecAccessControl → plain kSecAttrAccessible)

    @Test func testMigrateFromSecAccessControlToPlainAccessibility() async throws {
        try await keychainStore.deleteAll()
        let migrationKey = "KeychainIdentityStore.localFormatMigrationComplete"
        UserDefaults.standard.removeObject(forKey: migrationKey)

        let service = KeychainIdentityStore.defaultService

        // Given - save an identity, then recreate it with old SecAccessControl format
        let keys = try await keychainStore.generateKeys()
        let saved = try await keychainStore.save(inboxId: "format-inbox", clientId: "format-client", keys: keys)
        let savedData = try JSONEncoder().encode(saved)
        try await keychainStore.delete(inboxId: "format-inbox")

        guard let oldAccessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [],
            nil
        ) else {
            Issue.record("Failed to create access control")
            return
        }

        let oldAddQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrAccount as String: "format-inbox",
            kSecAttrGeneric as String: Data("format-client".utf8),
            kSecAttrAccessControl as String: oldAccessControl,
            kSecValueData as String: savedData
        ]
        let addStatus = SecItemAdd(oldAddQuery as CFDictionary, nil)
        #expect(addStatus == errSecSuccess, "Failed to add old-style item: \(addStatus)")

        // When
        KeychainIdentityStore.migrateToPlainAccessibilityIfNeeded(accessGroup: testAccessGroup)

        // Then - verify the item is still readable and data is preserved
        let loaded = try await keychainStore.identity(for: "format-inbox")
        #expect(loaded.inboxId == "format-inbox")
        #expect(loaded.clientId == "format-client")
        #expect(loaded.keys.databaseKey == keys.databaseKey)

        // Verify the item now has plain kSecAttrAccessible
        let checkQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrAccount as String: "format-inbox",
            kSecReturnAttributes as String: true
        ]
        var checkResult: CFTypeRef?
        let checkStatus = SecItemCopyMatching(checkQuery as CFDictionary, &checkResult)
        #expect(checkStatus == errSecSuccess)

        if let attrs = checkResult as? [String: Any],
           let accessible = attrs[kSecAttrAccessible as String] as? String {
            #expect(accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        }

        UserDefaults.standard.removeObject(forKey: migrationKey)
    }

    @Test func testLocalFormatMigrationIsIdempotent() async throws {
        try await keychainStore.deleteAll()
        let migrationKey = "KeychainIdentityStore.localFormatMigrationComplete"
        UserDefaults.standard.removeObject(forKey: migrationKey)

        // Given
        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(inboxId: "idempotent-inbox", clientId: "idempotent-client", keys: keys)

        // When - run migration twice (reset flag between runs)
        KeychainIdentityStore.migrateToPlainAccessibilityIfNeeded(accessGroup: testAccessGroup)
        UserDefaults.standard.removeObject(forKey: migrationKey)
        KeychainIdentityStore.migrateToPlainAccessibilityIfNeeded(accessGroup: testAccessGroup)

        // Then - data still intact
        let loaded = try await keychainStore.identity(for: "idempotent-inbox")
        #expect(loaded.inboxId == "idempotent-inbox")
        #expect(loaded.clientId == "idempotent-client")
        #expect(loaded.keys.databaseKey == keys.databaseKey)

        UserDefaults.standard.removeObject(forKey: migrationKey)
    }

    // MARK: - ICloudIdentityStore Tests

    private let testLocalService: String = "org.convos.test.local"
    private let testICloudService: String = "org.convos.test.icloud"

    private func makeICloudStore() -> ICloudIdentityStore {
        let local = KeychainIdentityStore(
            accessGroup: testAccessGroup,
            service: testLocalService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        let icloud = KeychainIdentityStore(
            accessGroup: testAccessGroup,
            service: testICloudService,
            accessibility: kSecAttrAccessibleAfterFirstUnlock
        )
        return ICloudIdentityStore(localStore: local, icloudStore: icloud)
    }

    private func makeRawLocalStore() -> KeychainIdentityStore {
        KeychainIdentityStore(
            accessGroup: testAccessGroup,
            service: testLocalService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    private func makeRawICloudStore() -> KeychainIdentityStore {
        KeychainIdentityStore(
            accessGroup: testAccessGroup,
            service: testICloudService,
            accessibility: kSecAttrAccessibleAfterFirstUnlock
        )
    }

    private func cleanupICloudStores() async throws {
        try await makeRawLocalStore().deleteAll()
        try await makeRawICloudStore().deleteAll()
    }

    @Test func testICloudStoreSavesToBothStores() async throws {
        try await cleanupICloudStores()

        // Given
        let store = makeICloudStore()
        let keys = try await store.generateKeys()

        // When
        _ = try await store.save(inboxId: "dual-inbox", clientId: "dual-client", keys: keys)

        // Then
        let localIdentities = try await makeRawLocalStore().loadAll()
        let icloudIdentities = try await makeRawICloudStore().loadAll()
        #expect(localIdentities.count == 1)
        #expect(icloudIdentities.count == 1)
        #expect(localIdentities[0].inboxId == "dual-inbox")
        #expect(icloudIdentities[0].inboxId == "dual-inbox")

        try await cleanupICloudStores()
    }

    @Test func testICloudStoreReadsPrefersLocal() async throws {
        try await cleanupICloudStores()

        // Given - different keys in each store
        let localStore = makeRawLocalStore()
        let icloudRawStore = makeRawICloudStore()
        let store = makeICloudStore()

        let localKeys = try await localStore.generateKeys()
        let icloudKeys = try await icloudRawStore.generateKeys()

        _ = try await localStore.save(inboxId: "pref-inbox", clientId: "pref-client", keys: localKeys)
        _ = try await icloudRawStore.save(inboxId: "pref-inbox", clientId: "pref-client", keys: icloudKeys)

        // When
        let loaded = try await store.identity(for: "pref-inbox")

        // Then - should get local keys
        #expect(loaded.keys.databaseKey == localKeys.databaseKey)

        try await cleanupICloudStores()
    }

    @Test func testICloudStoreFallsBackToICloud() async throws {
        try await cleanupICloudStores()

        // Given - only iCloud has the key (restore scenario)
        let icloudRawStore = makeRawICloudStore()
        let store = makeICloudStore()

        let icloudKeys = try await icloudRawStore.generateKeys()
        _ = try await icloudRawStore.save(inboxId: "fallback-inbox", clientId: "fallback-client", keys: icloudKeys)

        // When
        let loaded = try await store.identity(for: "fallback-inbox")

        // Then
        #expect(loaded.keys.databaseKey == icloudKeys.databaseKey)

        try await cleanupICloudStores()
    }

    @Test func testICloudFallbackCachesLocally() async throws {
        try await cleanupICloudStores()

        // Given - only iCloud has the key
        let icloudRawStore = makeRawICloudStore()
        let store = makeICloudStore()

        let icloudKeys = try await icloudRawStore.generateKeys()
        _ = try await icloudRawStore.save(inboxId: "cache-inbox", clientId: "cache-client", keys: icloudKeys)

        // When - read triggers fallback
        _ = try await store.identity(for: "cache-inbox")

        // Then - local should now have a cached copy
        let localIdentities = try await makeRawLocalStore().loadAll()
        #expect(localIdentities.count == 1)
        #expect(localIdentities[0].keys.databaseKey == icloudKeys.databaseKey)

        try await cleanupICloudStores()
    }

    @Test func testICloudStoreThrowsWhenBothEmpty() async throws {
        try await cleanupICloudStores()

        // Given
        let store = makeICloudStore()

        // When & Then
        do {
            _ = try await store.identity(for: "nonexistent")
            #expect(Bool(false), "Expected error")
        } catch {
            #expect(error is KeychainIdentityStoreError)
        }
    }

    @Test func testICloudStoreDeleteRemovesBoth() async throws {
        try await cleanupICloudStores()

        // Given
        let store = makeICloudStore()
        let keys = try await store.generateKeys()
        _ = try await store.save(inboxId: "del-inbox", clientId: "del-client", keys: keys)

        // When
        try await store.delete(inboxId: "del-inbox")

        // Then
        let localIdentities = try await makeRawLocalStore().loadAll()
        let icloudIdentities = try await makeRawICloudStore().loadAll()
        #expect(localIdentities.isEmpty)
        #expect(icloudIdentities.isEmpty)
    }

    @Test func testDeleteICloudCopyKeepsLocal() async throws {
        try await cleanupICloudStores()

        // Given
        let store = makeICloudStore()
        let keys = try await store.generateKeys()
        _ = try await store.save(inboxId: "keep-inbox", clientId: "keep-client", keys: keys)

        // When - delete only the iCloud copy
        try await store.deleteICloudCopy(inboxId: "keep-inbox")

        // Then - local is preserved, iCloud is gone
        let localIdentities = try await makeRawLocalStore().loadAll()
        let icloudIdentities = try await makeRawICloudStore().loadAll()
        #expect(localIdentities.count == 1)
        #expect(icloudIdentities.isEmpty)

        try await cleanupICloudStores()
    }

    @Test func testDeleteAllICloudCopiesKeepsLocal() async throws {
        try await cleanupICloudStores()

        // Given
        let store = makeICloudStore()
        let keys1 = try await store.generateKeys()
        let keys2 = try await store.generateKeys()
        _ = try await store.save(inboxId: "bulk-1", clientId: "client-1", keys: keys1)
        _ = try await store.save(inboxId: "bulk-2", clientId: "client-2", keys: keys2)

        // When
        try await store.deleteAllICloudCopies()

        // Then
        let localIdentities = try await makeRawLocalStore().loadAll()
        let icloudIdentities = try await makeRawICloudStore().loadAll()
        #expect(localIdentities.count == 2)
        #expect(icloudIdentities.isEmpty)

        try await cleanupICloudStores()
    }

    @Test func testHasICloudOnlyKeys() async throws {
        try await cleanupICloudStores()

        // Given - empty stores
        let store = makeICloudStore()
        #expect(await store.hasICloudOnlyKeys() == false)

        // When - add key to iCloud only (simulates restore scenario)
        let icloudRawStore = makeRawICloudStore()
        let keys = try await icloudRawStore.generateKeys()
        _ = try await icloudRawStore.save(inboxId: "restored-inbox", clientId: "restored-client", keys: keys)

        // Then
        #expect(await store.hasICloudOnlyKeys() == true)

        // When - add same key to local
        let localStore = makeRawLocalStore()
        _ = try await localStore.save(inboxId: "restored-inbox", clientId: "restored-client", keys: keys)

        // Then
        #expect(await store.hasICloudOnlyKeys() == false)

        try await cleanupICloudStores()
    }

    // MARK: - iCloud Sync Tests

    @Test func testSyncCopiesMissingKeysToICloud() async throws {
        try await cleanupICloudStores()

        // Given - keys in local only
        let localStore = makeRawLocalStore()
        let keys1 = try await localStore.generateKeys()
        let keys2 = try await localStore.generateKeys()
        _ = try await localStore.save(inboxId: "sync-inbox-1", clientId: "sync-client-1", keys: keys1)
        _ = try await localStore.save(inboxId: "sync-inbox-2", clientId: "sync-client-2", keys: keys2)

        // When
        let store = makeICloudStore()
        await store.syncLocalKeysToICloud()

        // Then - iCloud now has copies
        let icloudIdentities = try await makeRawICloudStore().loadAll()
        #expect(icloudIdentities.count == 2)
        #expect(icloudIdentities.contains { $0.inboxId == "sync-inbox-1" })
        #expect(icloudIdentities.contains { $0.inboxId == "sync-inbox-2" })

        try await cleanupICloudStores()
    }

    @Test func testSyncSkipsAlreadySyncedKeys() async throws {
        try await cleanupICloudStores()

        // Given - key in both stores
        let store = makeICloudStore()
        let keys = try await store.generateKeys()
        _ = try await store.save(inboxId: "already-synced", clientId: "already-client", keys: keys)

        // Add another key only to local
        let localStore = makeRawLocalStore()
        let keys2 = try await localStore.generateKeys()
        _ = try await localStore.save(inboxId: "not-synced", clientId: "not-client", keys: keys2)

        // When
        await store.syncLocalKeysToICloud()

        // Then - iCloud has both (original + newly synced)
        let icloudIdentities = try await makeRawICloudStore().loadAll()
        #expect(icloudIdentities.count == 2)

        try await cleanupICloudStores()
    }

    @Test func testSyncIsIdempotent() async throws {
        try await cleanupICloudStores()

        // Given
        let localStore = makeRawLocalStore()
        let keys = try await localStore.generateKeys()
        _ = try await localStore.save(inboxId: "idempotent-inbox", clientId: "idempotent-client", keys: keys)

        let store = makeICloudStore()

        // When - sync multiple times
        await store.syncLocalKeysToICloud()
        await store.syncLocalKeysToICloud()
        await store.syncLocalKeysToICloud()

        // Then - still just one copy
        let icloudIdentities = try await makeRawICloudStore().loadAll()
        #expect(icloudIdentities.count == 1)

        try await cleanupICloudStores()
    }

    @Test func testSyncAfterICloudCopiesDeleted() async throws {
        try await cleanupICloudStores()

        // Given - key in both stores
        let store = makeICloudStore()
        let keys = try await store.generateKeys()
        _ = try await store.save(inboxId: "resync-inbox", clientId: "resync-client", keys: keys)

        // When - iCloud copies are removed (simulates iCloud disable)
        try await store.deleteAllICloudCopies()
        let icloudBefore = try await makeRawICloudStore().loadAll()
        #expect(icloudBefore.isEmpty)

        // Then - sync restores iCloud copies (simulates iCloud re-enable)
        await store.syncLocalKeysToICloud()
        let icloudAfter = try await makeRawICloudStore().loadAll()
        #expect(icloudAfter.count == 1)
        #expect(icloudAfter[0].inboxId == "resync-inbox")

        try await cleanupICloudStores()
    }

    @Test func testSyncWithEmptyLocalStore() async throws {
        try await cleanupICloudStores()

        // Given - nothing in local
        let store = makeICloudStore()

        // When - should be a no-op
        await store.syncLocalKeysToICloud()

        // Then
        let icloudIdentities = try await makeRawICloudStore().loadAll()
        #expect(icloudIdentities.isEmpty)
    }

    @Test func testICloudAvailabilityDetection() {
        // Just verify the API exists and returns a boolean
        let available = ICloudIdentityStore.isICloudAvailable
        #expect(available == true || available == false)
    }
}
