import Foundation

public actor VaultKeyStore {
    private let localStore: any KeychainIdentityStoreProtocol
    private let icloudStore: any KeychainIdentityStoreProtocol

    public init(
        localStore: any KeychainIdentityStoreProtocol,
        icloudStore: any KeychainIdentityStoreProtocol
    ) {
        self.localStore = localStore
        self.icloudStore = icloudStore
    }

    public func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) async throws {
        _ = try await localStore.save(
            inboxId: inboxId,
            clientId: clientId,
            keys: keys
        )

        do {
            _ = try await icloudStore.save(
                inboxId: inboxId,
                clientId: clientId,
                keys: keys
            )
        } catch {
            Log.warning("Failed to save Vault key to iCloud Keychain: \(error)")
        }
    }

    public func load(inboxId: String) async throws -> KeychainIdentity {
        if let identity = try? await localStore.identity(for: inboxId) {
            return identity
        }

        let identity = try await icloudStore.identity(for: inboxId)

        _ = try await localStore.save(
            inboxId: identity.inboxId,
            clientId: identity.clientId,
            keys: identity.keys
        )

        return identity
    }

    public func loadFromAnyStore() async throws -> KeychainIdentity {
        let localIdentities = (try? await localStore.loadAll()) ?? []
        if let first = localIdentities.first {
            return first
        }

        let icloudIdentities = (try? await icloudStore.loadAll()) ?? []
        if let first = icloudIdentities.first {
            _ = try await localStore.save(
                inboxId: first.inboxId,
                clientId: first.clientId,
                keys: first.keys
            )
            return first
        }

        throw KeychainIdentityStoreError.identityNotFound("No Vault identity found in any store")
    }

    public func exists() async -> Bool {
        if let identities = try? await localStore.loadAll(), !identities.isEmpty {
            return true
        }
        if let identities = try? await icloudStore.loadAll(), !identities.isEmpty {
            return true
        }
        return false
    }

    public func delete(inboxId: String) async throws {
        try await localStore.delete(inboxId: inboxId)
        try await icloudStore.delete(inboxId: inboxId)
    }

    public func deleteAll() async throws {
        try await localStore.deleteAll()
        try await icloudStore.deleteAll()
    }
}
