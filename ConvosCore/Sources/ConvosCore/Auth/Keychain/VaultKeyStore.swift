import Foundation

public actor VaultKeyStore {
    private let localStore: any KeychainIdentityStoreProtocol
    private let icloudStore: any KeychainIdentityStoreProtocol
    private let vaultInboxId: String = "vault"
    private let vaultClientId: String = "vault"

    public init(
        localStore: any KeychainIdentityStoreProtocol,
        icloudStore: any KeychainIdentityStoreProtocol
    ) {
        self.localStore = localStore
        self.icloudStore = icloudStore
    }

    public func save(keys: KeychainIdentityKeys) async throws {
        _ = try await localStore.save(
            inboxId: vaultInboxId,
            clientId: vaultClientId,
            keys: keys
        )

        do {
            _ = try await icloudStore.save(
                inboxId: vaultInboxId,
                clientId: vaultClientId,
                keys: keys
            )
        } catch {
            Log.warning("Failed to save Vault key to iCloud Keychain: \(error)")
        }
    }

    public func load() async throws -> KeychainIdentityKeys {
        if let identity = try? await localStore.identity(for: vaultInboxId) {
            return identity.keys
        }

        let identity = try await icloudStore.identity(for: vaultInboxId)

        _ = try await localStore.save(
            inboxId: vaultInboxId,
            clientId: vaultClientId,
            keys: identity.keys
        )

        return identity.keys
    }

    public func exists() async -> Bool {
        if let identities = try? await localStore.loadAll(),
           identities.contains(where: { $0.inboxId == vaultInboxId }) {
            return true
        }
        if let identities = try? await icloudStore.loadAll(),
           identities.contains(where: { $0.inboxId == vaultInboxId }) {
            return true
        }
        return false
    }

    public func delete() async throws {
        try await localStore.delete(inboxId: vaultInboxId)
        try await icloudStore.delete(inboxId: vaultInboxId)
    }
}
