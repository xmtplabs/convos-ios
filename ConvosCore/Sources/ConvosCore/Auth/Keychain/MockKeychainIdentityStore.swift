import Foundation

actor MockKeychainIdentityStore: KeychainIdentityStoreProtocol {
    private var singleton: KeychainIdentity?

    func generateKeys() throws -> KeychainIdentityKeys {
        try KeychainIdentityKeys.generate()
    }

    func saveSingleton(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity {
        let identity = KeychainIdentity(inboxId: inboxId, clientId: clientId, keys: keys)
        singleton = identity
        return identity
    }

    func loadSingleton() throws -> KeychainIdentity? {
        singleton
    }

    func deleteSingleton() throws {
        singleton = nil
    }
}
