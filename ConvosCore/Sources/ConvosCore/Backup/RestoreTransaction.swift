import Foundation

/// Persisted record of an active restore. Together with `RestoreInProgressFlag`
/// (which is a boolean gate for the NSE + scheduler) this gives crash recovery
/// enough information to either roll back in-flight destructive ops or clear a
/// stale marker after a committed restore.
///
/// Invariants:
/// - Exactly one transaction is active at a time. `restoreInProgress` flag and
///   this record are set/cleared together.
/// - `paused` → `databaseReplaced` → `committed` is the only valid phase path.
/// - Pre-commit artifacts (XMTP stash + GRDB rollback snapshot file) live under
///   `<bookkeepingDir>/restore-transaction/<id>/` so a post-crash launch can
///   inspect and restore them.
public struct RestoreTransaction: Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var phase: Phase

    public enum Phase: String, Codable, Sendable {
        case paused
        case databaseReplaced
        case committed
    }

    public init(id: UUID = UUID(), startedAt: Date = Date(), phase: Phase = .paused) {
        self.id = id
        self.startedAt = startedAt
        self.phase = phase
    }
}

/// Store for the active `RestoreTransaction` record. Backed by app-group
/// `UserDefaults` so both the NSE and the next main-app launch can observe
/// an interrupted restore.
public enum RestoreTransactionStore {
    static let userDefaultsKey: String = "convos.backup.restoreTransaction"

    public static func save(_ record: RestoreTransaction, environment: AppEnvironment) {
        save(record, defaults: appGroupDefaults(for: environment))
    }

    public static func load(environment: AppEnvironment) -> RestoreTransaction? {
        load(defaults: appGroupDefaults(for: environment))
    }

    public static func clear(environment: AppEnvironment) {
        clear(defaults: appGroupDefaults(for: environment))
    }

    static func save(_ record: RestoreTransaction, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }

    static func load(defaults: UserDefaults) -> RestoreTransaction? {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(RestoreTransaction.self, from: data)
    }

    static func clear(defaults: UserDefaults) {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    private static func appGroupDefaults(for environment: AppEnvironment) -> UserDefaults {
        UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
    }
}

/// Filesystem layout helper for a restore transaction's rollback artifacts.
/// The directory sits under the shared app-group container so it survives
/// process termination.
public enum RestoreArtifactLayout {
    public static func transactionDirectory(
        for transactionId: UUID,
        environment: AppEnvironment
    ) -> URL {
        environment
            .backupBookkeepingDirectoryURL
            .appendingPathComponent("restore-transaction", isDirectory: true)
            .appendingPathComponent(transactionId.uuidString, isDirectory: true)
    }

    public static func xmtpStashDirectory(
        for transactionId: UUID,
        environment: AppEnvironment
    ) -> URL {
        transactionDirectory(for: transactionId, environment: environment)
            .appendingPathComponent("xmtp-stash", isDirectory: true)
    }

    public static func grdbSnapshotURL(
        for transactionId: UUID,
        environment: AppEnvironment
    ) -> URL {
        transactionDirectory(for: transactionId, environment: environment)
            .appendingPathComponent("grdb-rollback.sqlite")
    }
}
