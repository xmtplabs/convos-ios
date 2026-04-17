@testable import ConvosCore
import Foundation
import Testing

/// Smoke tests for the C3 keychain singleton + iCloud sync configuration.
///
/// Real iCloud Keychain sync cannot be exercised from a unit test — it requires
/// two devices signed in to the same Apple ID. These tests verify the knobs
/// we control: the service name bump (`.v3`), the fixed singleton account,
/// and the singleton API contract on the mock store.
///
/// Attribute-level verification (`kSecAttrSynchronizable == true`,
/// `kSecAttrAccessible == kSecAttrAccessibleAfterFirstUnlock`) happens in the
/// separate `KeychainIdentityStoreTests` target, which runs against a real
/// keychain with the necessary entitlements.
@Suite("Keychain Sync Config (C3)")
struct KeychainSyncConfigTests {
    @Test("Service name is bumped to .v3 so legacy entries do not collide")
    func serviceNameIsV3() {
        #expect(KeychainIdentityStore.defaultService == "org.convos.ios.KeychainIdentityStore.v3")
    }

    @Test("Singleton account key is a fixed, non-empty string")
    func singletonAccountIsFixed() {
        #expect(KeychainIdentityStore.singletonAccount == "single-inbox-identity")
        #expect(!KeychainIdentityStore.singletonAccount.isEmpty)
    }

    @Test("Singleton round-trip: save then load returns the same identity")
    func singletonRoundTrip() async throws {
        let store = MockKeychainIdentityStore()
        let keys = try await store.generateKeys()

        let saved = try await store.saveSingleton(
            inboxId: "inbox-abc",
            clientId: "client-xyz",
            keys: keys
        )
        #expect(saved.inboxId == "inbox-abc")
        #expect(saved.clientId == "client-xyz")

        let loaded = try await store.loadSingleton()
        #expect(loaded?.inboxId == "inbox-abc")
        #expect(loaded?.clientId == "client-xyz")
    }

    @Test("loadSingleton returns nil on a fresh store")
    func loadSingletonReturnsNilOnFreshStore() async throws {
        let store = MockKeychainIdentityStore()
        let loaded = try await store.loadSingleton()
        #expect(loaded == nil)
    }

    @Test("saveSingleton overwrites a previously saved singleton")
    func saveSingletonOverwrites() async throws {
        let store = MockKeychainIdentityStore()
        let firstKeys = try await store.generateKeys()
        let secondKeys = try await store.generateKeys()

        _ = try await store.saveSingleton(
            inboxId: "inbox-first",
            clientId: "client-first",
            keys: firstKeys
        )
        _ = try await store.saveSingleton(
            inboxId: "inbox-second",
            clientId: "client-second",
            keys: secondKeys
        )

        let loaded = try await store.loadSingleton()
        #expect(loaded?.inboxId == "inbox-second")
        #expect(loaded?.clientId == "client-second")
    }

    @Test("deleteSingleton clears the stored identity")
    func deleteSingletonClears() async throws {
        let store = MockKeychainIdentityStore()
        let keys = try await store.generateKeys()

        _ = try await store.saveSingleton(
            inboxId: "inbox-abc",
            clientId: "client-xyz",
            keys: keys
        )
        #expect(try await store.loadSingleton() != nil)

        try await store.deleteSingleton()
        #expect(try await store.loadSingleton() == nil)
    }
}
