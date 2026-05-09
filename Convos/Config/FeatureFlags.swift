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

    private enum Constant {
        static let assistantEnabledKey: String = "featureFlags.assistantEnabled"
    }
}
