import Foundation

actor MockKeychainIdentityStore: KeychainIdentityStoreProtocol {
    private var identity: KeychainIdentity?

    func generateKeys() throws -> KeychainIdentityKeys {
        try KeychainIdentityKeys.generate()
    }

    func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity {
        let identity = KeychainIdentity(inboxId: inboxId, clientId: clientId, keys: keys)
        self.identity = identity
        return identity
    }

    func load() throws -> KeychainIdentity? {
        identity
    }

    func delete() throws {
        identity = nil
    }
}
