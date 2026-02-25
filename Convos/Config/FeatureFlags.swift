import Foundation

@MainActor @Observable
final class FeatureFlags {
    static let shared: FeatureFlags = FeatureFlags()

    var isAssistantEnabled: Bool {
        get {
            guard !isProductionEnvironment else { return false }
            return UserDefaults.standard.bool(forKey: Constant.assistantEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constant.assistantEnabledKey)
        }
    }

    private var isProductionEnvironment: Bool {
        ConfigManager.shared.currentEnvironment.isProduction
    }

    private enum Constant {
        static let assistantEnabledKey: String = "featureFlags.assistantEnabled"
    }
}
