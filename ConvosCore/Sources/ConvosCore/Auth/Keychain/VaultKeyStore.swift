import Foundation

public actor VaultKeyStore {
    private let store: any KeychainIdentityStoreProtocol

    public init(store: any KeychainIdentityStoreProtocol) {
        self.store = store
    }

    @discardableResult
    public func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) async throws -> KeychainIdentity {
        try await store.save(
            inboxId: inboxId,
            clientId: clientId,
            keys: keys
        )
    }

    public func load(inboxId: String) async throws -> KeychainIdentity {
        try await store.identity(for: inboxId)
    }

    public func loadAny() async throws -> KeychainIdentity {
        let identities = try await store.loadAll()
        guard let first = identities.first else {
            throw KeychainIdentityStoreError.identityNotFound("No Vault identity found")
        }
        return first
    }

    public func exists() async -> Bool {
        guard let identities = try? await store.loadAll() else { return false }
        return !identities.isEmpty
    }

    public func delete(inboxId: String) async throws {
        try await store.delete(inboxId: inboxId)
    }

    /// Deletes only the local copy of the vault key, preserving the iCloud copy.
    /// Use this during "delete all data" flows so the iCloud key remains available
    /// for backup decryption on restore.
    public func deleteLocal(inboxId: String) async throws {
        if let dualStore = store as? ICloudIdentityStore {
            try await dualStore.deleteLocalOnly(inboxId: inboxId)
        } else {
            try await store.delete(inboxId: inboxId)
        }
    }

    public func deleteAll() async throws {
        try await store.deleteAll()
    }
}
