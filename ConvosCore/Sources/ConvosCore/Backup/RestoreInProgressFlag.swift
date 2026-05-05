import Foundation

/// Process-wide marker that a restore transaction is active.
///
/// Persisted in app-group `UserDefaults` so both the main app and the
/// NotificationService Extension can observe it. The NSE checks this at
/// `didReceive(_:withContentHandler:)` and bails with empty content when set,
/// and `BackupScheduler` reschedules on collision. Transaction-phase tracking
/// with rollback artifacts is layered on top of this flag in `RestoreManager`.
public enum RestoreInProgressFlag {
    static let userDefaultsKey: String = "convos.backup.restoreInProgress"

    public static func isSet(environment: AppEnvironment) -> Bool {
        isSet(defaults: appGroupDefaults(for: environment))
    }

    public static func set(_ value: Bool, environment: AppEnvironment) {
        set(value, defaults: appGroupDefaults(for: environment))
    }

    static func isSet(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: userDefaultsKey)
    }

    static func set(_ value: Bool, defaults: UserDefaults) {
        if value {
            defaults.set(true, forKey: userDefaultsKey)
        } else {
            defaults.removeObject(forKey: userDefaultsKey)
        }
    }

    private static func appGroupDefaults(for environment: AppEnvironment) -> UserDefaults {
        UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
    }
}
