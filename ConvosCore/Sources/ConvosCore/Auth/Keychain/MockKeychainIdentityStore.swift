import Foundation
import os

actor MockKeychainIdentityStore: KeychainIdentityStoreProtocol {
    /// Backed by an unfair lock so `loadSync` can read without hopping
    /// actor isolation — mirrors the real store's keychain-daemon-owned
    /// concurrency model.
    private let state: OSAllocatedUnfairLock<KeychainIdentity?> = .init(initialState: nil)
    /// Optional error injection for the load path. Tests simulating a
    /// transient keychain daemon failure set this to a non-nil `Error`;
    /// `loadSync` and `load` both throw it until the test clears it.
    private let loadError: OSAllocatedUnfairLock<(any Error)?> = .init(initialState: nil)

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
        if let error = loadError.withLock({ $0 }) {
            throw error
        }
        return state.withLock { $0 }
    }

    func delete() throws {
        state.withLock { $0 = nil }
    }

    func nudgeICloudSync() throws {
        // No iCloud Keychain to nudge in tests; in-memory state already
        // mirrors what `save` would re-write.
    }

    // MARK: - Two-key model (synced backup-only key)

    private let backupKey: OSAllocatedUnfairLock<Data?> = .init(initialState: nil)

    func loadBackupKeySync() throws -> Data? {
        backupKey.withLock { $0 }
    }

    func saveBackupKey(_ key: Data) throws {
        backupKey.withLock { $0 = key }
    }

    func deleteBackupKey() throws {
        backupKey.withLock { $0 = nil }
    }

    /// Test-only — inject an error for the next `loadSync`/`load` calls.
    /// Pass `nil` to clear.
    nonisolated func _setLoadError(_ error: (any Error)?) {
        loadError.withLock { $0 = error }
    }
}
