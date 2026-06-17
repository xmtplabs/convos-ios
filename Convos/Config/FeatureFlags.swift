import ConvosCore
import Foundation

@MainActor @Observable
final class FeatureFlags {
    static let shared: FeatureFlags = FeatureFlags()

    /// Off by default — gates the testtube debug-injector button in the composer
    /// media bar. Toggle from App Settings → Debug. Hard-locked off in production
    /// builds so the flag can never be `true` for end users, even if a UserDefaults
    /// value somehow leaks in from a dev build with the same bundle id.
    var isDebugInjectorEnabled: Bool {
        get {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return false }
            return UserDefaults.standard.bool(forKey: Constant.debugInjectorEnabledKey)
        }
        set {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
            UserDefaults.standard.set(newValue, forKey: Constant.debugInjectorEnabledKey)
        }
    }

    /// Off by default — routes the agent builder through the direct
    /// agent-templates generation API (submit -> poll -> invite) instead of the
    /// legacy conversation-as-transport flow. Toggle from App Settings → Debug.
    /// Hard-locked off in production while the flow is behind the flag.
    var isDirectAgentBuilderEnabled: Bool {
        get {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return false }
            return UserDefaults.standard.bool(forKey: Constant.directAgentBuilderEnabledKey)
        }
        set {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
            UserDefaults.standard.set(newValue, forKey: Constant.directAgentBuilderEnabledKey)
        }
    }

    /// Off by default — when on, the direct agent builder synthesizes a local
    /// `preview` + `progressPhrases` while a build runs, so the progress UI can
    /// be exercised before backend PR #309 ships. Remove once #309 is deployed.
    /// Toggle from App Settings → Debug. Hard-locked off in production.
    var isStubbedAgentGenerationProgressEnabled: Bool {
        get {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return false }
            return UserDefaults.standard.bool(forKey: Constant.stubbedAgentGenerationProgressKey)
        }
        set {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
            UserDefaults.standard.set(newValue, forKey: Constant.stubbedAgentGenerationProgressKey)
        }
    }

    /// Mock credits/subscription state used by the in-app paywall preview surface
    /// in the Debug menu. Non-production only; defaults to `.plusAmple`.
    var mockCreditsPreset: CreditsStatePreset {
        get {
            let raw = UserDefaults.standard.string(forKey: Constant.mockCreditsPresetKey)
                ?? CreditsStatePreset.plusAmple.rawValue
            return CreditsStatePreset(compatibleRawValue: raw) ?? .plusAmple
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Constant.mockCreditsPresetKey)
        }
    }

    private enum Constant {
        static let debugInjectorEnabledKey: String = "featureFlags.debugInjectorEnabled"
        static let mockCreditsPresetKey: String = "featureFlags.mockCreditsPreset"
        static let directAgentBuilderEnabledKey: String = "featureFlags.directAgentBuilderEnabled"
        static let stubbedAgentGenerationProgressKey: String = "featureFlags.stubbedAgentGenerationProgress"
    }
}
