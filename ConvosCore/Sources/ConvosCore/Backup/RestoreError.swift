import Foundation

/// Errors surfaced by the restore pipeline. Distinct cases per failure
/// class so the UI can branch on them — especially `schemaGenerationMismatch`,
/// which tells the user their bundle is too old without implying their
/// data is corrupt.
public enum RestoreError: Error, LocalizedError, Equatable {
    case identityNotAvailable
    case backupKeyNotAvailable
    case bundleCorrupt(String)
    case decryptionFailed(String)
    case schemaGenerationMismatch(bundleGeneration: String, currentGeneration: String)
    case missingComponent(String)
    case replaceDatabaseFailed(String)
    case restoreAlreadyInProgress

    public var errorDescription: String? {
        switch self {
        case .identityNotAvailable:
            return "iCloud Keychain is still syncing your identity. Please try again shortly."
        case .backupKeyNotAvailable:
            return "The backup key isn't available on this Apple ID. "
                + "If you tapped Start fresh, the backup is no longer recoverable."
        case .bundleCorrupt(let reason):
            return "The backup appears corrupt: \(reason)"
        case .decryptionFailed(let reason):
            return "Failed to decrypt the backup: \(reason)"
        case .schemaGenerationMismatch:
            return "This backup was made on an older version of Convos and can't be restored. "
                + "Try a newer backup, or start fresh."
        case .missingComponent(let name):
            return "Backup is missing required component: \(name)"
        case .replaceDatabaseFailed(let reason):
            return "Failed to restore the database: \(reason)"
        case .restoreAlreadyInProgress:
            return "A restore is already in progress."
        }
    }

    public static func == (lhs: RestoreError, rhs: RestoreError) -> Bool {
        switch (lhs, rhs) {
        case (.identityNotAvailable, .identityNotAvailable),
            (.backupKeyNotAvailable, .backupKeyNotAvailable),
            (.restoreAlreadyInProgress, .restoreAlreadyInProgress):
            return true
        case let (.bundleCorrupt(a), .bundleCorrupt(b)),
            let (.decryptionFailed(a), .decryptionFailed(b)),
            let (.missingComponent(a), .missingComponent(b)),
            let (.replaceDatabaseFailed(a), .replaceDatabaseFailed(b)):
            return a == b
        case let (.schemaGenerationMismatch(a1, a2), .schemaGenerationMismatch(b1, b2)):
            return a1 == b1 && a2 == b2
        default:
            return false
        }
    }
}

/// In-process restore progress observable by the UI. `archiveImportFailed`
/// is a terminal partial-success state — the GRDB restore committed but
/// the XMTP archive import did not complete. `BackupRestoreSettingsView`
/// surfaces a follow-up warning when this appears.
public enum RestoreState: Sendable, Equatable {
    case idle
    case decrypting
    case replacingDatabase
    case importingArchive
    case completed
    case archiveImportFailed(reason: String)
    case failed(String)
}

/// Persisted summary of a previous archive-import failure. Carried in
/// app-group UserDefaults (not in-memory) so the UI can keep showing the
/// warning across app relaunches until the user re-runs restore.
public struct PendingArchiveImportFailure: Codable, Equatable, Sendable {
    public let occurredAt: Date
    public let reason: String

    public init(occurredAt: Date = Date(), reason: String) {
        self.occurredAt = occurredAt
        self.reason = reason
    }
}

/// Records that the user tapped "Not now" on the fresh-install restore
/// prompt for a specific bundle. The signal is **per-device** (lives
/// in app-group UserDefaults, never iCloud Keychain) — so dismissing
/// the prompt on Device A doesn't propagate to Device B and never
/// touches the synced backup key.
///
/// The fingerprint is `deviceId + createdAt`, so if a paired device
/// produces a *newer* bundle later, the prompt re-appears (the user
/// only opted out of the bundle they saw, not all future bundles).
public enum RestorePromptDismissalStorage {
    static let userDefaultsKey: String = "convos.backup.restorePromptDismissedFingerprint"

    public static func fingerprint(for sidecar: BackupSidecarMetadata) -> String {
        "\(sidecar.deviceId)|\(sidecar.createdAt.timeIntervalSince1970)"
    }

    public static func record(
        _ sidecar: BackupSidecarMetadata,
        environment: AppEnvironment
    ) {
        record(sidecar, defaults: appGroupDefaults(for: environment))
    }

    public static func isDismissed(
        _ sidecar: BackupSidecarMetadata,
        environment: AppEnvironment
    ) -> Bool {
        isDismissed(sidecar, defaults: appGroupDefaults(for: environment))
    }

    public static func clear(environment: AppEnvironment) {
        appGroupDefaults(for: environment).removeObject(forKey: userDefaultsKey)
    }

    static func record(_ sidecar: BackupSidecarMetadata, defaults: UserDefaults) {
        defaults.set(fingerprint(for: sidecar), forKey: userDefaultsKey)
    }

    static func isDismissed(_ sidecar: BackupSidecarMetadata, defaults: UserDefaults) -> Bool {
        guard let stored = defaults.string(forKey: userDefaultsKey) else { return false }
        return stored == fingerprint(for: sidecar)
    }

    private static func appGroupDefaults(for environment: AppEnvironment) -> UserDefaults {
        UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
    }
}

/// Helper for persisting / reading `PendingArchiveImportFailure` via
/// app-group UserDefaults. Separate from `RestoreInProgressFlag` because
/// the failure summary outlives any single restore transaction.
public enum PendingArchiveImportFailureStorage {
    static let userDefaultsKey: String = "convos.backup.pendingArchiveImportFailure"

    public static func save(_ failure: PendingArchiveImportFailure, environment: AppEnvironment) {
        save(failure, defaults: appGroupDefaults(for: environment))
    }

    public static func load(environment: AppEnvironment) -> PendingArchiveImportFailure? {
        load(defaults: appGroupDefaults(for: environment))
    }

    public static func clear(environment: AppEnvironment) {
        clear(defaults: appGroupDefaults(for: environment))
    }

    static func save(_ failure: PendingArchiveImportFailure, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(failure) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }

    static func load(defaults: UserDefaults) -> PendingArchiveImportFailure? {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(PendingArchiveImportFailure.self, from: data)
    }

    static func clear(defaults: UserDefaults) {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    private static func appGroupDefaults(for environment: AppEnvironment) -> UserDefaults {
        UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
    }
}
