import Foundation

actor MockKeychainIdentityStore: KeychainIdentityStoreProtocol {
    private var savedIdentities: [String: KeychainIdentity] = [:]

    func generateKeys() throws -> KeychainIdentityKeys {
        try KeychainIdentityKeys.generate()
    }

    func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity {
        let identity = KeychainIdentity(inboxId: inboxId, clientId: clientId, keys: keys)
        savedIdentities[inboxId] = identity
        return identity
    }

    func identity(for inboxId: String) throws -> KeychainIdentity {
        guard let identity = savedIdentities[inboxId] else {
            throw KeychainIdentityStoreError.identityNotFound("Identity not found for inboxId: \(inboxId)")
        }
        return identity
    }

    func loadAll() throws -> [KeychainIdentity] {
        return Array(savedIdentities.values)
    }

    func delete(inboxId: String) throws {
        savedIdentities.removeValue(forKey: inboxId)
    }

    func delete(clientId: String) throws -> KeychainIdentity {
        // Find the identity with matching clientId
        guard let identity = savedIdentities.values.first(where: { $0.clientId == clientId }) else {
            throw KeychainIdentityStoreError.identityNotFound("No identity found with clientId: \(clientId)")
        }

        // Delete using the inboxId key
        savedIdentities.removeValue(forKey: identity.inboxId)
        return identity
    }

    func deleteAll() throws {
        savedIdentities.removeAll()
    }
}
