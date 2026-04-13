import Foundation
import Security

/// Coordinates two keychain stores for iCloud backup of identity keys.
///
/// Wraps a local `ThisDeviceOnly` store and an iCloud `AfterFirstUnlock` store:
/// - save: writes to both (iCloud failure is non-fatal)
/// - identity(for:): reads local first, falls back to iCloud (and caches locally)
/// - delete: removes from both
/// - deleteLocalOnly: removes only the local copy while preserving iCloud
///
/// The local copy is the normal safety net. Restore flows can explicitly remove
/// only the local copy while keeping the iCloud copy available for disaster recovery.
/// Items written to the iCloud store with `AfterFirstUnlock` accessibility are
/// automatically synced by iOS when iCloud Keychain is enabled at the system level.
/// When iCloud Keychain is disabled, items remain local; when re-enabled, they sync.
public actor ICloudIdentityStore: KeychainIdentityStoreProtocol {
    private let localStore: any KeychainIdentityStoreProtocol
    private let icloudStore: any KeychainIdentityStoreProtocol

    public init(
        localStore: any KeychainIdentityStoreProtocol,
        icloudStore: any KeychainIdentityStoreProtocol
    ) {
        self.localStore = localStore
        self.icloudStore = icloudStore
    }

    /// Convenience initializer using standard keychain services
    public init(accessGroup: String) {
        self.localStore = KeychainIdentityStore(
            accessGroup: accessGroup,
            service: KeychainIdentityStore.defaultService,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        self.icloudStore = KeychainIdentityStore(
            accessGroup: accessGroup,
            service: KeychainIdentityStore.icloudService,
            accessibility: kSecAttrAccessibleAfterFirstUnlock,
            synchronizable: true
        )
    }

    // MARK: - KeychainIdentityStoreProtocol

    public func generateKeys() throws -> KeychainIdentityKeys {
        try KeychainIdentityKeys.generate()
    }

    public func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) async throws -> KeychainIdentity {
        let identity = try await localStore.save(inboxId: inboxId, clientId: clientId, keys: keys)

        do {
            _ = try await icloudStore.save(inboxId: inboxId, clientId: clientId, keys: keys)
        } catch {
            Log.warning("Failed to save identity to iCloud Keychain: \(error)")
        }

        return identity
    }

    public func identity(for inboxId: String) async throws -> KeychainIdentity {
        if let identity = try? await localStore.identity(for: inboxId) {
            return identity
        }

        let identity = try await icloudStore.identity(for: inboxId)

        _ = try? await localStore.save(inboxId: identity.inboxId, clientId: identity.clientId, keys: identity.keys)

        return identity
    }

    public func loadAll() async throws -> [KeychainIdentity] {
        let localIdentities = try await localStore.loadAll()
        let icloudIdentities = (try? await icloudStore.loadAll()) ?? []

        guard !icloudIdentities.isEmpty else { return localIdentities }

        let localInboxIds = Set(localIdentities.map(\.inboxId))
        let icloudOnly = icloudIdentities.filter { !localInboxIds.contains($0.inboxId) }

        return localIdentities + icloudOnly
    }

    public func delete(inboxId: String) async throws {
        try await localStore.delete(inboxId: inboxId)
        do {
            try await icloudStore.delete(inboxId: inboxId)
        } catch {
            Log.warning("Failed to delete identity from iCloud Keychain: \(inboxId): \(error)")
        }
    }

    /// Deletes only the local copy, preserving the iCloud copy.
    /// The iCloud copy serves as the backup decryption key and must survive local data wipes.
    public func deleteLocalOnly(inboxId: String) async throws {
        try await localStore.delete(inboxId: inboxId)
    }

    public func delete(clientId: String) async throws -> KeychainIdentity {
        // Try local first. If the key only exists in iCloud (e.g. after a
        // local wipe), the local delete throws "not found" and we fall
        // through to iCloud. Other errors (device locked, etc.) propagate.
        do {
            let identity = try await localStore.delete(clientId: clientId)
            do {
                _ = try await icloudStore.delete(clientId: clientId)
            } catch {
                Log.warning("Failed to delete identity from iCloud Keychain by clientId: \(clientId): \(error)")
            }
            return identity
        } catch is KeychainIdentityStoreError {
            return try await icloudStore.delete(clientId: clientId)
        }
    }

    public func deleteAll() async throws {
        try await localStore.deleteAll()
        do {
            try await icloudStore.deleteAll()
        } catch {
            Log.warning("Failed to delete all identities from iCloud Keychain: \(error)")
        }
    }

    // MARK: - iCloud sync

    /// Ensures all local keys have a copy in the iCloud store.
    ///
    /// Safe to call on every app launch. Skips keys that already exist in iCloud.
    /// When iCloud Keychain is disabled at the system level, items are stored locally
    /// in the iCloud service and will sync automatically when iCloud is re-enabled.
    public func syncLocalKeysToICloud() async {
        guard let localIdentities = try? await localStore.loadAll(), !localIdentities.isEmpty else {
            return
        }

        let icloudIdentities = (try? await icloudStore.loadAll()) ?? []
        let icloudInboxIds = Set(icloudIdentities.map(\.inboxId))

        var syncedCount = 0
        for identity in localIdentities {
            guard !icloudInboxIds.contains(identity.inboxId) else { continue }

            do {
                _ = try await icloudStore.save(
                    inboxId: identity.inboxId,
                    clientId: identity.clientId,
                    keys: identity.keys
                )
                syncedCount += 1
            } catch {
                Log.warning("Failed to sync key to iCloud: \(identity.inboxId): \(error)")
            }
        }

        if syncedCount > 0 {
            Log.info("iCloud key sync: copied \(syncedCount) key(s) to iCloud service")
        }
    }

    /// Whether keys exist in the iCloud store but not locally (restore scenario).
    public func hasICloudOnlyKeys() async -> Bool {
        let localIdentities = (try? await localStore.loadAll()) ?? []
        let icloudIdentities = (try? await icloudStore.loadAll()) ?? []

        guard !icloudIdentities.isEmpty else { return false }

        let localInboxIds = Set(localIdentities.map(\.inboxId))
        return icloudIdentities.contains { !localInboxIds.contains($0.inboxId) }
    }

    // MARK: - iCloud-specific operations

    /// Removes only the iCloud copy for a specific inbox
    public func deleteICloudCopy(inboxId: String) async throws {
        try await icloudStore.delete(inboxId: inboxId)
    }

    /// Removes all iCloud copies
    public func deleteAllICloudCopies() async throws {
        try await icloudStore.deleteAll()
    }

    // MARK: - iCloud availability detection

    /// Whether an iCloud account is available on the device.
    ///
    /// This checks for iCloud account presence via `ubiquityIdentityToken`.
    /// It does not indicate whether iCloud Keychain is enabled.
    /// Apple does not provide a public API to directly query iCloud Keychain status.
    public nonisolated static var isICloudAccountAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    @available(*, deprecated, renamed: "isICloudAccountAvailable", message: "Checks iCloud account availability, not iCloud Keychain status.")
    public nonisolated static var isICloudAvailable: Bool {
        isICloudAccountAvailable
    }
}
