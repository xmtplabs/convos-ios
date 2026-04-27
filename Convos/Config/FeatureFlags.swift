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

    /// Cloud Connections = Composio-brokered SaaS integrations. Separate from
    /// Device Connections (on-device Apple-SDK pathway in `ConvosConnections`).
    var isCloudConnectionsEnabled: Bool {
        get {
            guard let stored = UserDefaults.standard.object(forKey: Constant.cloudConnectionsEnabledKey) as? Bool else {
                return false
            }
            return stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constant.cloudConnectionsEnabledKey)
        }
    }

    private enum Constant {
        static let assistantEnabledKey: String = "featureFlags.assistantEnabled"
        static let cloudConnectionsEnabledKey: String = "featureFlags.cloudConnectionsEnabled"
    }
}
