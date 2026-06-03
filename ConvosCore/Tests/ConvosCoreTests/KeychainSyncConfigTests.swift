@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

/// Smoke tests for keychain identity storage configuration.
///
/// The primary identity slot is device-local (`kSecAttrSynchronizable:
/// false`); a separate synced backup slot (`kSecAttrSynchronizable: true`)
/// mirrors the identity into iCloud Keychain for recovery. These tests
/// verify the knobs we control without hitting the real keychain: the
/// service names, the fixed account key, and the API contract on the
/// mock store.
///
/// Attribute-level verification (`kSecAttrSynchronizable == false` on the
/// real saved item, `kSecAttrAccessible == kSecAttrAccessibleAfterFirstUnlock`,
/// the backup landing in the synced store) lives in the separate
/// `KeychainIdentityStoreTests` target, which runs against a real keychain
/// with the necessary entitlements.
@Suite("Keychain Sync Config")
struct KeychainSyncConfigTests {
    @Test("Service name is stable across launches")
    func serviceNameIsStable() {
        #expect(KeychainIdentityStore.defaultService == "org.convos.ios.KeychainIdentityStore.v3")
    }

    @Test("Synced backup service name is stable and distinct from the primary")
    func syncedBackupServiceNameIsStable() {
        #expect(KeychainIdentityStore.syncedBackupService == "org.convos.ios.KeychainIdentityStore.v3-synced-backup")
        #expect(KeychainIdentityStore.syncedBackupService != KeychainIdentityStore.defaultService)
    }

    @Test("Identity account key is a fixed, non-empty string")
    func identityAccountIsFixed() {
        #expect(KeychainIdentityStore.identityAccount == "convos-identity")
        #expect(!KeychainIdentityStore.identityAccount.isEmpty)
    }

    @Test("loadSync returns the same identity as load")
    func loadSyncMatchesLoad() async throws {
        let store = MockKeychainIdentityStore()
        let keys = try await store.generateKeys()

        _ = try await store.save(
            inboxId: "sync-inbox",
            clientId: "sync-client",
            keys: keys
        )

        let loaded = try await store.load()
        let loadedSync = try store.loadSync()
        #expect(loaded?.inboxId == loadedSync?.inboxId)
        #expect(loaded?.clientId == loadedSync?.clientId)
    }

    @Test("loadSync returns nil on a fresh store")
    func loadSyncReturnsNilWhenEmpty() throws {
        let store = MockKeychainIdentityStore()
        let loaded = try store.loadSync()
        #expect(loaded == nil)
    }

    @Test("Round-trip: save then load returns the same identity")
    func roundTrip() async throws {
        let store = MockKeychainIdentityStore()
        let keys = try await store.generateKeys()

        let saved = try await store.save(
            inboxId: "inbox-abc",
            clientId: "client-xyz",
            keys: keys
        )
        #expect(saved.inboxId == "inbox-abc")
        #expect(saved.clientId == "client-xyz")

        let loaded = try await store.load()
        #expect(loaded?.inboxId == "inbox-abc")
        #expect(loaded?.clientId == "client-xyz")
    }

    @Test("load returns nil on a fresh store")
    func loadReturnsNilOnFreshStore() async throws {
        let store = MockKeychainIdentityStore()
        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test("save overwrites a previously saved identity")
    func saveOverwrites() async throws {
        let store = MockKeychainIdentityStore()
        let firstKeys = try await store.generateKeys()
        let secondKeys = try await store.generateKeys()

        _ = try await store.save(
            inboxId: "inbox-first",
            clientId: "client-first",
            keys: firstKeys
        )
        _ = try await store.save(
            inboxId: "inbox-second",
            clientId: "client-second",
            keys: secondKeys
        )

        let loaded = try await store.load()
        #expect(loaded?.inboxId == "inbox-second")
        #expect(loaded?.clientId == "client-second")
    }

    @Test("delete clears the stored identity")
    func deleteClears() async throws {
        let store = MockKeychainIdentityStore()
        let keys = try await store.generateKeys()

        _ = try await store.save(
            inboxId: "inbox-abc",
            clientId: "client-xyz",
            keys: keys
        )
        #expect(try await store.load() != nil)

        try await store.delete()
        #expect(try await store.load() == nil)
    }

    @Test("loadSyncedBackups returns empty on a fresh store")
    func syncedBackupsAreEmptyOnFreshStore() async throws {
        let store = MockKeychainIdentityStore()
        let backups = try await store.loadSyncedBackups()
        #expect(backups.isEmpty)
    }

    @Test("save mirrors the identity into the synced backup slot")
    func saveMirrorsIntoSyncedBackup() async throws {
        let store = MockKeychainIdentityStore()
        let keys = try await store.generateKeys()

        _ = try await store.save(
            inboxId: "backup-inbox",
            clientId: "backup-client",
            keys: keys
        )

        let backups = try await store.loadSyncedBackups()
        #expect(backups.count == 1)
        #expect(backups.first?.inboxId == "backup-inbox")
        #expect(backups.first?.clientId == "backup-client")
        #expect(backups.first?.deviceName == MockKeychainIdentityStore.mockDeviceName)
        #expect(backups.first?.backedUpAt != nil)
    }

    @Test("backup metadata fields are optional when decoding")
    func backupMetadataIsOptionalWhenDecoding() throws {
        // A blob written without restore-display metadata must still
        // decode -- metadata can never make a backup unrecoverable.
        let keys = try KeychainIdentityKeys.generate()
        let json: [String: Any] = [
            "inboxId": "bare-inbox",
            "clientId": "bare-client",
            "privateKeyData": keys.privateKey.secp256K1.bytes.base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(KeychainIdentityBackup.self, from: data)
        #expect(decoded.inboxId == "bare-inbox")
        #expect(decoded.deviceName == nil)
        #expect(decoded.backedUpAt == nil)
    }

    @Test("delete clears the deleted identity's synced backup too")
    func deleteClearsSyncedBackup() async throws {
        let store = MockKeychainIdentityStore()
        let keys = try await store.generateKeys()

        _ = try await store.save(
            inboxId: "backup-inbox",
            clientId: "backup-client",
            keys: keys
        )
        #expect(try await store.loadSyncedBackups().count == 1)

        try await store.delete()
        #expect(try await store.loadSyncedBackups().isEmpty)
    }

    @Test("a displacing save removes the displaced identity's backup")
    func displacingSaveRemovesDisplacedBackup() async throws {
        let store = MockKeychainIdentityStore()
        let placeholderKeys = try await store.generateKeys()
        let pairedKeys = try await store.generateKeys()

        // Models pairing: the fresh-install placeholder identity is
        // displaced by the shared identity. The placeholder's backup
        // must not be left orphaned in iCloud.
        _ = try await store.save(
            inboxId: "placeholder-inbox",
            clientId: "placeholder-client",
            keys: placeholderKeys
        )
        _ = try await store.save(
            inboxId: "paired-inbox",
            clientId: "paired-client",
            keys: pairedKeys
        )

        let backups = try await store.loadSyncedBackups()
        #expect(backups.map(\.inboxId) == ["paired-inbox"])
    }

    @Test("re-saving the same identity keeps a single backup entry")
    func resavingSameIdentityKeepsSingleBackup() async throws {
        let store = MockKeychainIdentityStore()
        let firstKeys = try await store.generateKeys()
        let secondKeys = try await store.generateKeys()

        _ = try await store.save(
            inboxId: "stable-inbox",
            clientId: "client-one",
            keys: firstKeys
        )
        _ = try await store.save(
            inboxId: "stable-inbox",
            clientId: "client-two",
            keys: secondKeys
        )

        let backups = try await store.loadSyncedBackups()
        #expect(backups.count == 1)
        #expect(backups.first?.clientId == "client-two")
    }

    @Test("backup excludes the database key")
    func backupExcludesDatabaseKey() async throws {
        let store = MockKeychainIdentityStore()
        let keys = try await store.generateKeys()

        let saved = try await store.save(
            inboxId: "slim-inbox",
            clientId: "slim-client",
            keys: keys
        )

        let backup = try #require(try await store.loadSyncedBackups().first)
        let encoded = try JSONEncoder().encode(backup)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["databaseKey"] == nil)
        #expect(json["privateKeyData"] != nil)
        #expect(backup.privateKey.secp256K1.bytes == saved.keys.privateKey.secp256K1.bytes)
    }

    @Test("backfill repopulates a missing synced backup from the primary slot")
    func backfillRepopulatesMissingBackup() async throws {
        let store = MockKeychainIdentityStore()
        let keys = try await store.generateKeys()

        _ = try await store.save(
            inboxId: "backfill-inbox",
            clientId: "backfill-client",
            keys: keys
        )
        store._clearSyncedBackups()
        #expect(try await store.loadSyncedBackups().isEmpty)

        await store.backfillSyncedBackupIfNeeded()

        let backups = try await store.loadSyncedBackups()
        #expect(backups.first?.inboxId == "backfill-inbox")
        #expect(backups.first?.clientId == "backfill-client")
    }

    @Test("backfill is a no-op on an empty store")
    func backfillIsNoOpOnEmptyStore() async throws {
        let store = MockKeychainIdentityStore()

        await store.backfillSyncedBackupIfNeeded()

        #expect(try await store.load() == nil)
        #expect(try await store.loadSyncedBackups().isEmpty)
    }
}
