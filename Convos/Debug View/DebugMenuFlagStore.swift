import ConvosCore
import Foundation
import Observation

/// Persistent on/off flag for the curated prod debug menu.
///
/// Stored in plain `UserDefaults.standard` (main app only; the Notification
/// Service Extension does not need it). The flag is OFF by default and stays
/// enabled until the user explicitly turns it off -- there is no auto-expiry
/// and no cold-launch clear.
///
/// `isEnabled` is a computed property over UserDefaults, and the Observable
/// macro only instruments stored properties, so the accessor registers with
/// the observation registrar by hand -- `access(keyPath:)` in get,
/// `withMutation(keyPath:)` around the write -- mirroring `FeatureFlags`.
/// Views whose bodies read the flag (the App Settings "Debug menu" row via
/// `DebugMenuGate`, and the "Debug mode" toggle inside `ProdDebugMenuView`)
/// re-evaluate the moment it is toggled from anywhere; without the registrar
/// calls a flip only shows up after the view is rebuilt for some other
/// reason.
///
/// Every write goes through the setter so the transition is logged with a
/// readback of the persisted value; an exported log bundle can then
/// distinguish "enable never ran" from "write did not persist".
@MainActor @Observable
final class DebugMenuFlagStore {
    static let shared: DebugMenuFlagStore = DebugMenuFlagStore()

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return UserDefaults.standard.bool(forKey: Constant.enabledKey)
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.enabledKey)
            }
            let readback = UserDefaults.standard.bool(forKey: Constant.enabledKey)
            Log.info("DebugMenuFlagStore: setEnabled(\(newValue)), readback=\(readback)")
        }
    }

    func enable() {
        isEnabled = true
    }

    private enum Constant {
        static let enabledKey: String = "convos.debugMenu.enabled.v1"
    }
}
