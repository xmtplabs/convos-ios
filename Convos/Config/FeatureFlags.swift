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

    /// Mock credits/subscription state used by the in-app paywall preview surface
    /// in the Debug menu. Non-production only; defaults to `.builderAmple`.
    var mockCreditsPreset: CreditsStatePreset {
        get {
            let raw = UserDefaults.standard.string(forKey: Constant.mockCreditsPresetKey)
                ?? CreditsStatePreset.builderAmple.rawValue
            return CreditsStatePreset(rawValue: raw) ?? .builderAmple
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Constant.mockCreditsPresetKey)
        }
    }

    private enum Constant {
        static let debugInjectorEnabledKey: String = "featureFlags.debugInjectorEnabled"
        static let mockCreditsPresetKey: String = "featureFlags.mockCreditsPreset"
    }
}
