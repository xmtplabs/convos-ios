import Foundation
import os

actor MockKeychainIdentityStore: KeychainIdentityStoreProtocol {
    /// Fixed device name stamped on mock backups, mirroring the real
    /// store's lazily-provided `DeviceInfo.deviceName`.
    static let mockDeviceName: String = "Mock Device"

    /// Backed by an unfair lock so `loadSync` can read without hopping
    /// actor isolation — mirrors the real store's keychain-daemon-owned
    /// concurrency model.
    private let state: OSAllocatedUnfairLock<KeychainIdentity?> = .init(initialState: nil)
    /// In-memory stand-in for the iCloud-synced backup slot, keyed by
    /// inboxId — one entry per backed-up identity, like the real store's
    /// per-identity accounts.
    private let backupState: OSAllocatedUnfairLock<[String: KeychainIdentityBackup]> = .init(initialState: [:])
    /// In-memory stand-in for the device-local installation marker slot.
    private let markerState: OSAllocatedUnfairLock<InstallationMarker?> = .init(initialState: nil)
    /// In-memory stand-in for the device-local consent backup slot.
    private let consentBackupState: OSAllocatedUnfairLock<ConsentBackup?> = .init(initialState: nil)
    /// Optional error injection for the load path. Tests simulating a
    /// transient keychain daemon failure set this to a non-nil `Error`;
    /// `loadSync` and `load` both throw it until the test clears it.
    private let loadError: OSAllocatedUnfairLock<(any Error)?> = .init(initialState: nil)

    func generateKeys() throws -> KeychainIdentityKeys {
        try KeychainIdentityKeys.generate()
    }

    func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity {
        let identity = KeychainIdentity(inboxId: inboxId, clientId: clientId, keys: keys)
        let displacedInboxId = state.withLock { $0?.inboxId }
        state.withLock { $0 = identity }
        backupState.withLock { backups in
            if let displacedInboxId, displacedInboxId != inboxId {
                backups.removeValue(forKey: displacedInboxId)
            }
            backups[inboxId] = KeychainIdentityBackup(
                identity: identity,
                deviceName: Self.mockDeviceName,
                backedUpAt: Date()
            )
        }
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

    func loadSyncedBackups() throws -> [KeychainIdentityBackup] {
        backupState.withLock { Array($0.values) }
    }

    func backfillSyncedBackupIfNeeded() {
        guard let identity = try? loadSync() else { return }
        backupState.withLock { backups in
            if backups[identity.inboxId] == nil {
                backups[identity.inboxId] = KeychainIdentityBackup(
                    identity: identity,
                    deviceName: Self.mockDeviceName,
                    backedUpAt: Date()
                )
            }
        }
    }

    func delete() throws {
        let inboxId = state.withLock { $0?.inboxId }
        state.withLock { $0 = nil }
        if let inboxId {
            backupState.withLock { $0.removeValue(forKey: inboxId) }
        }
        markerState.withLock { $0 = nil }
        consentBackupState.withLock { $0 = nil }
    }

    func loadInstallationMarker() throws -> InstallationMarker? {
        markerState.withLock { $0 }
    }

    func saveInstallationMarker(_ marker: InstallationMarker) throws {
        markerState.withLock { $0 = marker }
    }

    func loadConsentBackup() throws -> ConsentBackup? {
        consentBackupState.withLock { $0 }
    }

    func saveConsentBackup(_ backup: ConsentBackup) throws {
        consentBackupState.withLock { $0 = backup }
    }

    /// Test-only — inject an error for the next `loadSync`/`load` calls.
    /// Pass `nil` to clear.
    nonisolated func _setLoadError(_ error: (any Error)?) {
        loadError.withLock { $0 = error }
    }

    /// Test-only — clears just the synced backup slot so backfill paths
    /// can be exercised (every `save` mirrors into the backup, so this
    /// state is otherwise unreachable through the public API).
    nonisolated func _clearSyncedBackups() {
        backupState.withLock { $0.removeAll() }
    }
}
