import ConvosCore
import Foundation

/// Persistent on/off flag for the curated prod debug menu.
///
/// Stored in plain `UserDefaults.standard` (main app only; the Notification
/// Service Extension does not need it). The flag is OFF by default and stays
/// enabled until the user explicitly turns it off -- there is no auto-expiry
/// and no cold-launch clear.
///
/// In production the getter returns `false` unless the flag is explicitly set,
/// mirroring the defensive posture of `FeatureFlags.isDebugInjectorEnabled`:
/// a stray UserDefaults value leaking in from a non-prod build with the same
/// bundle id can never silently enable the menu.
enum DebugMenuFlagStore {
    static func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Constant.enabledKey)
    }

    static func enable() {
        setEnabled(true)
    }

    static func disable() {
        setEnabled(false)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Constant.enabledKey)
    }

    private enum Constant {
        static let enabledKey: String = "convos.debugMenu.enabled.v1"
    }
}
