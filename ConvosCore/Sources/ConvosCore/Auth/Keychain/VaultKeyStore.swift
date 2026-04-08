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

    public func loadAll() async throws -> [KeychainIdentity] {
        try await store.loadAll()
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
    ///
    /// Only effective when the underlying store is an `ICloudIdentityStore` (the
    /// production configuration). For non-iCloud stores (mocks/tests with a single
    /// keychain), this is a no-op — falling through to a full `delete` would
    /// contradict the documented intent of preserving the iCloud copy. Tests that
    /// need to verify deletion should call `delete(inboxId:)` directly.
    public func deleteLocal(inboxId: String) async throws {
        guard let dualStore = store as? ICloudIdentityStore else {
            Log.warning("VaultKeyStore.deleteLocal called on non-iCloud store; no-op to preserve documented contract")
            return
        }
        try await dualStore.deleteLocalOnly(inboxId: inboxId)
    }

    public func deleteAll() async throws {
        try await store.deleteAll()
    }
}
