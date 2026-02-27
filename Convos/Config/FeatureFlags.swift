import Foundation

@MainActor @Observable
final class FeatureFlags {
    static let shared: FeatureFlags = FeatureFlags()

    var isAssistantEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Constant.assistantEnabledKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: Constant.assistantEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constant.assistantEnabledKey)
        }
    }

    private enum Constant {
        static let assistantEnabledKey: String = "featureFlags.assistantEnabled"
    }
}
