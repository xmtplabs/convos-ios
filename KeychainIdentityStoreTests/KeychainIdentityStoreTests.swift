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
        Self.sweepAllSlots(accessGroup: testAccessGroup)
    }

    /// Swift Testing creates a fresh suite instance per test, so this runs
    /// before every test: it clears the primary slot and every backup item
    /// (including orphans from interrupted earlier runs), so no test
    /// depends on declaration order or a prior test's cleanup. `delete()`
    /// alone can't guarantee this because it scopes backup removal to the
    /// current primary's inboxId.
    private static func sweepAllSlots(accessGroup: String) {
        let services = [KeychainIdentityStore.defaultService, KeychainIdentityStore.syncedBackupService]
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
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

    /// `KeychainIdentityStore` writes with `kSecAttrSynchronizable: false`,
    /// so the saved item must live in the device-local store and **not** in
    /// the iCloud-synced one. iOS treats synced and non-synced items as
    /// separate stores even with the same service+account, so a query that
    /// pins `kSecAttrSynchronizable: true` must miss it.
    @Test func savedIdentityIsDeviceLocalNotSynced() async throws {
        try await keychainStore.delete()

        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "sync-check-inbox",
            clientId: "sync-check-client",
            keys: keys
        )

        // Pinned non-sync query → must find the item.
        let nonSyncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.defaultService,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var nonSyncResult: CFTypeRef?
        let nonSyncStatus = SecItemCopyMatching(nonSyncQuery as CFDictionary, &nonSyncResult)
        #expect(nonSyncStatus == errSecSuccess, "Item should be present in the device-local slot (status=\(nonSyncStatus))")

        // Pinned sync query → must NOT find the item.
        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.defaultService,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrSynchronizable as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var syncResult: CFTypeRef?
        let syncStatus = SecItemCopyMatching(syncQuery as CFDictionary, &syncResult)
        #expect(syncStatus == errSecItemNotFound, "Item must not be in the iCloud-synced slot (status=\(syncStatus))")
    }

    /// `save` mirrors the identity into the synced backup slot
    /// (`syncedBackupService`, account = inboxId, `kSecAttrSynchronizable:
    /// true`), so a pinned sync query on the backup service must find it
    /// and a pinned non-sync query must miss it — the inverse of the
    /// primary slot.
    @Test func savedIdentityIsMirroredIntoSyncedBackupSlot() async throws {
        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "backup-check-inbox",
            clientId: "backup-check-client",
            keys: keys
        )

        // Pinned sync query on the backup service → must find the item.
        var syncResult: CFTypeRef?
        let syncStatus = SecItemCopyMatching(
            backupSlotReadQuery(inboxId: "backup-check-inbox", synchronizable: true) as CFDictionary,
            &syncResult
        )
        #expect(syncStatus == errSecSuccess, "Backup must be present in the iCloud-synced slot (status=\(syncStatus))")

        // Pinned non-sync query on the backup service → must NOT find the item.
        var nonSyncResult: CFTypeRef?
        let nonSyncStatus = SecItemCopyMatching(
            backupSlotReadQuery(inboxId: "backup-check-inbox", synchronizable: false) as CFDictionary,
            &nonSyncResult
        )
        #expect(nonSyncStatus == errSecItemNotFound, "Backup must not be in the device-local store (status=\(nonSyncStatus))")
    }

    @Test func loadSyncedBackupsRoundTrip() async throws {
        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "backup-load-inbox",
            clientId: "backup-load-client",
            keys: keys
        )

        let backups = try keychainStore.loadSyncedBackups()
        #expect(backups.count == 1)
        #expect(backups.first?.inboxId == "backup-load-inbox")
        #expect(backups.first?.clientId == "backup-load-client")
    }

    /// Re-saving the same inboxId hits the `errSecDuplicateItem` ->
    /// `SecItemUpdate` path on the synchronizable backup item — semantics
    /// the mock cannot model. The updated clientId proves the blob was
    /// rewritten in place rather than duplicated or left stale.
    @Test func resavingSameIdentityUpdatesBackupInPlace() async throws {
        let firstKeys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "resave-inbox",
            clientId: "resave-client-one",
            keys: firstKeys
        )

        let secondKeys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "resave-inbox",
            clientId: "resave-client-two",
            keys: secondKeys
        )

        let backups = try keychainStore.loadSyncedBackups()
        #expect(backups.count == 1)
        #expect(backups.first?.inboxId == "resave-inbox")
        #expect(backups.first?.clientId == "resave-client-two")
    }

    /// A save that displaces a different identity (pairing overwriting the
    /// fresh-install placeholder) must remove the displaced identity's
    /// backup instead of leaving it orphaned in iCloud.
    @Test func displacingSaveRemovesDisplacedBackup() async throws {
        let placeholderKeys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "displaced-inbox",
            clientId: "displaced-client",
            keys: placeholderKeys
        )

        let pairedKeys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "incoming-inbox",
            clientId: "incoming-client",
            keys: pairedKeys
        )

        let backups = try keychainStore.loadSyncedBackups()
        #expect(backups.map(\.inboxId) == ["incoming-inbox"])
    }

    @Test func deleteClearsSyncedBackupSlot() async throws {
        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "backup-delete-inbox",
            clientId: "backup-delete-client",
            keys: keys
        )
        #expect(try keychainStore.loadSyncedBackups().count == 1)

        try await keychainStore.delete()
        #expect(try keychainStore.loadSyncedBackups().isEmpty)
    }

    /// Two unpaired identities sharing an iCloud account must back up
    /// side by side. Simulated by saving identity A, clearing only the
    /// device-local primary slot (as if this were a different device),
    /// then saving identity B. With no primary present, B's save sees no
    /// displaced identity, so A's backup survives.
    @Test func unpairedIdentitiesCoexistInBackupSlot() async throws {
        let firstKeys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "coexist-inbox-a",
            clientId: "coexist-client-a",
            keys: firstKeys
        )
        deletePrimarySlotOnly()

        let secondKeys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "coexist-inbox-b",
            clientId: "coexist-client-b",
            keys: secondKeys
        )

        let backedUpInboxIds = Set(try keychainStore.loadSyncedBackups().map(\.inboxId))
        #expect(backedUpInboxIds == ["coexist-inbox-a", "coexist-inbox-b"])

        // Deleting the current identity (B) must leave A's backup intact.
        try await keychainStore.delete()
        let remaining = try keychainStore.loadSyncedBackups()
        #expect(remaining.map(\.inboxId) == ["coexist-inbox-a"])
    }

    /// Simulates an install that saved its identity before the backup
    /// slot existed: primary populated, backup missing. Backfill must
    /// mirror the primary into the backup without touching the primary.
    @Test func backfillRestoresMissingSyncedBackup() async throws {
        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "backfill-inbox",
            clientId: "backfill-client",
            keys: keys
        )

        // Remove just the backup copy, leaving the primary slot intact.
        let deleteStatus = SecItemDelete(backupSlotQuery(inboxId: "backfill-inbox", synchronizable: true) as CFDictionary)
        #expect(deleteStatus == errSecSuccess)
        #expect(try keychainStore.loadSyncedBackups().isEmpty)

        await keychainStore.backfillSyncedBackupIfNeeded()

        let backups = try keychainStore.loadSyncedBackups()
        #expect(backups.first?.inboxId == "backfill-inbox")
        #expect(backups.first?.clientId == "backfill-client")

        let primary = try await keychainStore.load()
        #expect(primary?.inboxId == "backfill-inbox")
    }

    /// Documents the orphan edge: when the primary slot is already gone,
    /// `delete()` cannot scope the backup removal, so the backup survives
    /// (reclaimable via LegacyDataWipe on a generation bump). This is the
    /// deliberate trade-off versus sweeping the whole backup service,
    /// which would destroy other devices' backups.
    @Test func deleteWithMissingPrimaryLeavesBackupOrphaned() async throws {
        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "orphan-inbox",
            clientId: "orphan-client",
            keys: keys
        )
        deletePrimarySlotOnly()

        try await keychainStore.delete()

        #expect(try await keychainStore.load() == nil)
        #expect(try keychainStore.loadSyncedBackups().map(\.inboxId) == ["orphan-inbox"])
    }

    /// One corrupt blob must not poison recovery: `loadSyncedBackups`
    /// skips items that fail to decode and returns the rest.
    @Test func loadSyncedBackupsSkipsCorruptBlob() async throws {
        addRawBackupItem(account: "corrupt-account", data: Data("not json".utf8))

        let keys = try await keychainStore.generateKeys()
        _ = try await keychainStore.save(
            inboxId: "valid-inbox",
            clientId: "valid-client",
            keys: keys
        )

        let backups = try keychainStore.loadSyncedBackups()
        #expect(backups.map(\.inboxId) == ["valid-inbox"])
    }

    /// The backup blob carries restore-display metadata: the writing
    /// device's name (from the injected provider, evaluated lazily at
    /// write time) and the backup date.
    @Test func backupRecordsDeviceNameAndDate() async throws {
        let namedStore = KeychainIdentityStore(
            accessGroup: testAccessGroup,
            deviceNameProvider: { "Test iPhone" }
        )
        let keys = try await namedStore.generateKeys()
        let beforeSave = Date()
        _ = try await namedStore.save(
            inboxId: "named-inbox",
            clientId: "named-client",
            keys: keys
        )

        let backup = try #require(try namedStore.loadSyncedBackups().first)
        #expect(backup.deviceName == "Test iPhone")
        let backedUpAt = try #require(backup.backedUpAt)
        #expect(backedUpAt >= beforeSave)
        #expect(backedUpAt <= Date())

        // The default store (no provider) writes nil rather than failing.
        _ = try await keychainStore.save(
            inboxId: "named-inbox",
            clientId: "named-client-two",
            keys: keys
        )
        let rewritten = try #require(try keychainStore.loadSyncedBackups().first)
        #expect(rewritten.deviceName == nil)
        #expect(rewritten.clientId == "named-client-two")
    }

    /// Confirms the kSecMatchLimitAll enumeration holds beyond two items.
    @Test func loadSyncedBackupsEnumeratesManyItems() async throws {
        for index in 1...3 {
            let keys = try await keychainStore.generateKeys()
            _ = try await keychainStore.save(
                inboxId: "many-inbox-\(index)",
                clientId: "many-client-\(index)",
                keys: keys
            )
            deletePrimarySlotOnly()
        }

        let backedUpInboxIds = Set(try keychainStore.loadSyncedBackups().map(\.inboxId))
        #expect(backedUpInboxIds == ["many-inbox-1", "many-inbox-2", "many-inbox-3"])
    }

    /// Removes only the device-local primary slot, leaving every synced
    /// backup in place — simulates a different device sharing the same
    /// iCloud account.
    private func deletePrimarySlotOnly() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.defaultService,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrSynchronizable as String: false
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    /// Writes a raw item directly into the backup service, bypassing the
    /// store — used to plant corrupt blobs.
    private func addRawBackupItem(account: String, data: Data) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.syncedBackupService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrSynchronizable as String: true
        ]
        query[kSecValueData as String] = data
        _ = SecItemAdd(query as CFDictionary, nil)
    }

    /// Base attribute query for one identity's backup item. Suitable for
    /// `SecItemDelete`, which rejects read-only keys like `kSecMatchLimit`
    /// on iOS.
    private func backupSlotQuery(inboxId: String, synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.syncedBackupService,
            kSecAttrAccount as String: inboxId,
            kSecAttrAccessGroup as String: testAccessGroup,
            kSecAttrSynchronizable as String: synchronizable
        ]
    }

    private func backupSlotReadQuery(inboxId: String, synchronizable: Bool) -> [String: Any] {
        var query = backupSlotQuery(inboxId: inboxId, synchronizable: synchronizable)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        return query
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
