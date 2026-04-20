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

    var isConnectionsEnabled: Bool {
        get {
            guard let stored = UserDefaults.standard.object(forKey: Constant.connectionsEnabledKey) as? Bool else {
                return false
            }
            return stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constant.connectionsEnabledKey)
        }
    }

    private enum Constant {
        static let assistantEnabledKey: String = "featureFlags.assistantEnabled"
        static let connectionsEnabledKey: String = "featureFlags.connectionsEnabled"
    }
}
