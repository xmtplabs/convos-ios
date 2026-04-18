import Foundation
import os

actor MockKeychainIdentityStore: KeychainIdentityStoreProtocol {
    /// Backed by an unfair lock so `loadSync` can read without hopping
    /// actor isolation — mirrors the real store's keychain-daemon-owned
    /// concurrency model.
    private let state: OSAllocatedUnfairLock<KeychainIdentity?> = .init(initialState: nil)

    func generateKeys() throws -> KeychainIdentityKeys {
        try KeychainIdentityKeys.generate()
    }

    func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity {
        let identity = KeychainIdentity(inboxId: inboxId, clientId: clientId, keys: keys)
        state.withLock { $0 = identity }
        return identity
    }

    func load() throws -> KeychainIdentity? {
        try loadSync()
    }

    nonisolated func loadSync() throws -> KeychainIdentity? {
        state.withLock { $0 }
    }

    func delete() throws {
        state.withLock { $0 = nil }
    }
}
