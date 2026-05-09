import Foundation

@MainActor @Observable
final class FeatureFlags {
    static let shared: FeatureFlags = FeatureFlags()

    var isAssistantEnabled: Bool {
        get {
            guard let stored = UserDefaults.standard.object(forKey: Constant.assistantEnabledKey) as? Bool else {
                return true
            }
            return stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constant.assistantEnabledKey)
        }
    }

    /// Off by default — gates the testtube debug-injector button in the composer
    /// media bar (and its DEBUG-only sheet). Toggle from App Settings → Debug.
    var isDebugInjectorEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Constant.debugInjectorEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Constant.debugInjectorEnabledKey) }
    }

    private enum Constant {
        static let assistantEnabledKey: String = "featureFlags.assistantEnabled"
        static let debugInjectorEnabledKey: String = "featureFlags.debugInjectorEnabled"
    }
}
