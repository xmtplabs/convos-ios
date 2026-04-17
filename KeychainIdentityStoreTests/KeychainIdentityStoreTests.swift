import ConvosCore
import Foundation
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
