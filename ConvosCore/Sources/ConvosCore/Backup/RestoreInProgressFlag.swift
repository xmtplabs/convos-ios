import Foundation

/// Process-crossing signal that an iCloud restore is actively rewriting
/// the shared GRDB database and the XMTP local DB files.
///
/// Lives in the app-group `UserDefaults` so the main app and the
/// NotificationService Extension can both read it. Set by
/// `SessionManager.pauseForRestore()` and cleared by
/// `resumeAfterRestore()`.
///
/// Consumers:
/// - `DatabaseManager.replaceDatabase` wraps the swap in an
///   `NSFileCoordinator` write barrier; this flag is the fast
///   pre-check for readers that want to bail **before** opening
///   coordinated handles.
/// - The NSE early-exits with an empty content delivery when the
///   flag is set — push loss within a narrow user-initiated window
///   is an acceptable trade for not risking a torn read.
/// - `BackupScheduler` skips + reschedules while the flag is set.
public enum RestoreInProgressFlag {
    private static let key: String = "convos.restore-in-progress.flag"

    public enum FlagError: Error, LocalizedError {
        case appGroupUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case let .appGroupUnavailable(groupId):
                return "App-group UserDefaults (\(groupId)) unavailable; cannot signal restore-in-progress to the NSE"
            }
        }
    }

    /// The in-process-only flag — guarded separately by
    /// `SessionManager` inside its `cachedMessagingService` lock.
    /// See `docs/plans/icloud-backup-single-inbox.md`
    /// §"Throwaway XMTP client for archive import" for why the
    /// app-group flag alone doesn't close the in-process race.
    ///
    /// Read path is lenient: "container unavailable" degrades to
    /// `false`, which matches the pre-flag NSE behavior of
    /// attempting delivery. This is safe because the coordinator +
    /// in-process gate close the same race even if this flag
    /// silently fails to read.
    public static func isSet(environment: AppEnvironment) -> Bool {
        defaults(environment: environment)?.bool(forKey: key) ?? false
    }

    /// Strict: throws if the app-group container is unavailable.
    /// `SessionManager.pauseForRestore` must abort the restore on
    /// throw rather than proceeding into destructive ops with an
    /// un-signaled NSE.
    public static func set(_ value: Bool, environment: AppEnvironment) throws {
        guard let defaults = defaults(environment: environment) else {
            throw FlagError.appGroupUnavailable(environment.appGroupIdentifier)
        }
        defaults.set(value, forKey: key)
    }

    private static func defaults(environment: AppEnvironment) -> UserDefaults? {
        UserDefaults(suiteName: environment.appGroupIdentifier)
    }
}

/// Error surfaced by `SessionManager.loadOrCreateService()` while a
/// restore is actively in-process. Observers see
/// `SessionStateMachine.State.error(RestoreInProgressError)` and can
/// render a "Restoring…" banner instead of attempting recovery.
///
/// Not a `TerminalSessionError` — the state clears by design when
/// `SessionManager.resumeAfterRestore()` nilpotently cleans up.
public struct RestoreInProgressError: Error, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "Restore in progress"
    }
}
