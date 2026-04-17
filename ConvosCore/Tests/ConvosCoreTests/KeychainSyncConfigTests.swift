@testable import ConvosCore
import Foundation
import Testing

/// Smoke tests for keychain identity storage + iCloud sync configuration.
///
/// Real iCloud Keychain sync can't be exercised from a unit test — it requires
/// two devices signed in to the same Apple ID. These tests verify the knobs
/// we control: the service name, the fixed account key, and the API contract
/// on the mock store.
///
/// Attribute-level verification (`kSecAttrSynchronizable == true`,
/// `kSecAttrAccessible == kSecAttrAccessibleAfterFirstUnlock`) lives in the
/// separate `KeychainIdentityStoreTests` target, which runs against a real
/// keychain with the necessary entitlements.
@Suite("Keychain Sync Config")
struct KeychainSyncConfigTests {
    @Test("Service name is stable across launches")
    func serviceNameIsStable() {
        #expect(KeychainIdentityStore.defaultService == "org.convos.ios.KeychainIdentityStore.v3")
    }

    @Test("Identity account key is a fixed, non-empty string")
    func identityAccountIsFixed() {
        #expect(KeychainIdentityStore.identityAccount == "convos-identity")
        #expect(!KeychainIdentityStore.identityAccount.isEmpty)
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
}
