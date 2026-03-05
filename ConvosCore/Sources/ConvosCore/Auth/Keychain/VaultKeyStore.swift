import Foundation

public actor VaultKeyStore {
    private let localStore: any KeychainKeyStoreProtocol
    private let icloudStore: any KeychainKeyStoreProtocol
    private let identifier: String = "vault"

    public init(
        localStore: any KeychainKeyStoreProtocol,
        icloudStore: any KeychainKeyStoreProtocol
    ) {
        self.localStore = localStore
        self.icloudStore = icloudStore
    }

    public func save(keys: KeychainIdentityKeys) async throws {
        try await localStore.save(
            keys: keys,
            identifier: identifier,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )

        do {
            try await icloudStore.save(
                keys: keys,
                identifier: identifier,
                accessibility: .afterFirstUnlock
            )
        } catch {
            Log.warning("Failed to save Vault key to iCloud Keychain: \(error)")
        }
    }

    public func load() async throws -> KeychainIdentityKeys {
        if let keys = try? await localStore.load(identifier: identifier) {
            return keys
        }

        let keys = try await icloudStore.load(identifier: identifier)

        try await localStore.save(
            keys: keys,
            identifier: identifier,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )

        return keys
    }

    public func exists() async -> Bool {
        if let localExists = try? await localStore.exists(identifier: identifier), localExists {
            return true
        }
        if let icloudExists = try? await icloudStore.exists(identifier: identifier), icloudExists {
            return true
        }
        return false
    }

    public func delete() async throws {
        try await localStore.delete(identifier: identifier)
        try await icloudStore.delete(identifier: identifier)
    }
}
