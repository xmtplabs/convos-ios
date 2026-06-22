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
        // `UserDefaults.didChangeNotification` does not fire for same-process
        // `UserDefaults.standard` writes, so surfaces that key off the flag
        // (e.g. the app-wide debug indicator) would otherwise only update on
        // relaunch. Post an explicit notification they can observe directly.
        NotificationCenter.default.post(name: .debugMenuFlagChanged, object: nil)
    }

    private enum Constant {
        static let enabledKey: String = "convos.debugMenu.enabled.v1"
    }
}

extension Notification.Name {
    /// Posted whenever `DebugMenuFlagStore` mutates the persisted prod debug
    /// menu flag. Lets in-process surfaces refresh without waiting for a
    /// relaunch, which `UserDefaults.didChangeNotification` cannot guarantee
    /// for same-process `UserDefaults.standard` writes.
    static let debugMenuFlagChanged: Notification.Name = Notification.Name(
        "convos.debugMenu.flagChanged"
    )
}
