import ConvosCore
import Foundation
import Testing

/// Test suite for KeychainIdentityStore
@Suite(.serialized) class KeychainIdentityStoreExampleTests {
    // MARK: - Test Properties

    private let keychainStore: KeychainIdentityStore
    private let testAccessGroup: String = "FY4NZR34Z3.org.convos.KeychainIdentityStoreExample"

    init() throws {
        keychainStore = KeychainIdentityStore(accessGroup: testAccessGroup)
    }

    // MARK: - Helper Methods

    private func createKeychainStore() -> KeychainIdentityStoreProtocol {
        return KeychainIdentityStore(accessGroup: testAccessGroup)
    }

    // MARK: - Identity Management Tests

    @Test func testGenerateKeys() async throws {
        // When
        let keys = try await keychainStore.generateKeys()

        // Then
        #expect(keys.databaseKey.count == 32) // 256-bit key
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
        // Given
        let nonExistentInboxId = "non-existent-inbox"

        // When & Then
        do {
            _ = try await keychainStore.identity(for: nonExistentInboxId)
            #expect(Bool(false), "Expected error when loading non-existent identity")
        } catch {
            // Expected to throw an error
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
            // Expected to throw an error
            #expect(error is KeychainIdentityStoreError)
        }

        // Verify it's not in the list
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

        // When - Delete using clientId instead of inboxId
        _ = try await keychainStore.delete(clientId: clientId)

        // Then - Identity should be deleted
        do {
            _ = try await keychainStore.identity(for: inboxId)
            #expect(Bool(false), "Expected error when loading deleted identity")
        } catch {
            // Expected to throw an error
            #expect(error is KeychainIdentityStoreError)
        }

        // Verify it's not in the list
        let allIdentities = try await keychainStore.loadAll()
        #expect(!allIdentities.contains { $0.clientId == clientId })
    }

    @Test func testDeleteNonExistentIdentity() async throws {
        try await keychainStore.deleteAll()

        // Given
        let nonExistentInboxId = "non-existent-inbox"

        // When & Then - Should not throw
        try await keychainStore.delete(inboxId: nonExistentInboxId)
    }

    @Test func testDeleteByNonExistentClientId() async throws {
        try await keychainStore.deleteAll()

        // Given
        let nonExistentClientId = "non-existent-client"

        // When & Then - Should throw an error
        do {
            _ = try await keychainStore.delete(clientId: nonExistentClientId)
            #expect(Bool(false), "Expected error when deleting non-existent clientId")
        } catch {
            // Expected to throw an error
            #expect(error is KeychainIdentityStoreError)
        }
    }

    // MARK: - Error Handling Tests

    @Test func testConcurrentIdentityOperations() async throws {
        try await keychainStore.deleteAll()

        // Given
        let numberOfIdentities = 10
        let store = keychainStore

        // When - Create multiple identities concurrently
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

        // Verify all identities are unique
        let inboxIds = Set(identities.map { $0.inboxId })
        #expect(inboxIds.count == numberOfIdentities)

        // Verify we can load all identities
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

    @Test func testCompleteCleanup() async throws {
        try await keychainStore.deleteAll()

        // Given
        let keys1 = try await keychainStore.generateKeys()
        let keys2 = try await keychainStore.generateKeys()

        let identity1 = try await keychainStore.save(inboxId: "cleanup-inbox1", clientId: "cleanup-client1", keys: keys1)
        let identity2 = try await keychainStore.save(inboxId: "cleanup-inbox2", clientId: "cleanup-client2", keys: keys2)

        // Verify data exists
        #expect(try await keychainStore.loadAll().count == 2)

        // When - Delete identities
        try await keychainStore.delete(inboxId: identity1.inboxId)
        try await keychainStore.delete(inboxId: identity2.inboxId)

        // Then
        #expect(try await keychainStore.loadAll().isEmpty)

        // Identities should not be loadable
        do {
            _ = try await keychainStore.identity(for: identity1.inboxId)
            #expect(Bool(false), "Identity should be cleaned up")
        } catch {
            // Expected
        }

        do {
            _ = try await keychainStore.identity(for: identity2.inboxId)
            #expect(Bool(false), "Identity should be cleaned up")
        } catch {
            // Expected
        }
    }

    @Test func testDeleteAll() async throws {
        try await keychainStore.deleteAll()

        // Given - Create multiple identities
        let keys1 = try await keychainStore.generateKeys()
        let keys2 = try await keychainStore.generateKeys()
        let keys3 = try await keychainStore.generateKeys()

        let identity1 = try await keychainStore.save(inboxId: "delete-all-inbox1", clientId: "delete-all-client1", keys: keys1)
        let identity2 = try await keychainStore.save(inboxId: "delete-all-inbox2", clientId: "delete-all-client2", keys: keys2)
        let identity3 = try await keychainStore.save(inboxId: "delete-all-inbox3", clientId: "delete-all-client3", keys: keys3)

        // Verify data exists
        #expect(try await keychainStore.loadAll().count == 3)
        #expect(try await keychainStore.identity(for: identity1.inboxId).inboxId == identity1.inboxId)

        // When - Delete all data
        try await keychainStore.deleteAll()

        // Then - All identities should be gone
        #expect(try await keychainStore.loadAll().isEmpty)

        // Individual identities should not be loadable
        do {
            _ = try await keychainStore.identity(for: identity1.inboxId)
            #expect(Bool(false), "Identity should be cleaned up")
        } catch {
            // Expected
        }

        do {
            _ = try await keychainStore.identity(for: identity2.inboxId)
            #expect(Bool(false), "Identity should be cleaned up")
        } catch {
            // Expected
        }

        do {
            _ = try await keychainStore.identity(for: identity3.inboxId)
            #expect(Bool(false), "Identity should be cleaned up")
        } catch {
            // Expected
        }
    }

    @Test func testDeleteAllWhenEmpty() async throws {
        try await keychainStore.deleteAll()

        // Given - Empty keychain store
        #expect(try await keychainStore.loadAll().isEmpty)

        // When & Then - Should not throw when deleting all from empty store
        try await keychainStore.deleteAll()
        #expect(try await keychainStore.loadAll().isEmpty)
    }

    // MARK: - KeychainIdentityKeys Tests

    @Test func testKeychainIdentityKeysGeneration() async throws {
        try await keychainStore.deleteAll()

        // When
        let keys = try await keychainStore.generateKeys()

        // Then
        #expect(keys.databaseKey.count == 32) // 256-bit key
    }

    @Test func testKeychainIdentityKeysCoding() async throws {
        try await keychainStore.deleteAll()

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
        let inboxId = "coding-test-inbox"
        let clientId = "coding-test-client"
        let keys = try await keychainStore.generateKeys()
        let identity = try await keychainStore.save(inboxId: inboxId, clientId: clientId, keys: keys)

        // When
        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(KeychainIdentity.self, from: encoded)

        // Then
        #expect(decoded.inboxId == identity.inboxId)
        #expect(decoded.keys.databaseKey == identity.keys.databaseKey)
    }
}
