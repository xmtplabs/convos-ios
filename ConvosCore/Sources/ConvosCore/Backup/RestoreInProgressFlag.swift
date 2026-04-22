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
    private static let suiteName: String = "convos.restore-in-progress"
    private static let key: String = "convos.restore-in-progress.flag"

    /// The in-process-only flag — guarded separately by
    /// `SessionManager` inside its `cachedMessagingService` lock.
    /// See `docs/plans/icloud-backup-single-inbox.md`
    /// §"Throwaway XMTP client for archive import" for why the
    /// app-group flag alone doesn't close the in-process race.
    public static func isSet(environment: AppEnvironment) -> Bool {
        defaults(environment: environment)?.bool(forKey: key) ?? false
    }

    public static func set(_ value: Bool, environment: AppEnvironment) {
        guard let defaults = defaults(environment: environment) else {
            Log.warning("RestoreInProgressFlag: app-group defaults unavailable; flag not written")
            return
        }
        defaults.set(value, forKey: key)
    }

    private static func defaults(environment: AppEnvironment) -> UserDefaults? {
        UserDefaults(suiteName: environment.appGroupIdentifier)
    }
}
