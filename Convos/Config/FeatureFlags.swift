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

    /// Off by default -- gates the dev-only agent variant selector that appears
    /// in the make-an-agent composer. Toggle from App Settings -> Debug. Hard-
    /// locked off in production so the selector can never surface for end users.
    var isAgentVariantSelectorEnabled: Bool {
        get {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return false }
            return UserDefaults.standard.bool(forKey: Constant.agentVariantSelectorEnabledKey)
        }
        set {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
            UserDefaults.standard.set(newValue, forKey: Constant.agentVariantSelectorEnabledKey)
            // Clear any cached selection when the feature is turned off so a
            // stale variant can't resurface on re-enable. Reads are already
            // gated on this flag; clearing keeps the persisted state honest too.
            if !newValue {
                selectedAgentVariant = nil
            }
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

    /// Dev-only agent variant chosen in the make-an-agent composer's selector.
    /// The full bundle is cached (not just the slug) so the selected detail
    /// renders without a fetch; the selector reconciles it against the live
    /// registry. The build reads `slug` once at Make and carries it through all
    /// three calls. Hard-locked to `nil` in production builds so a leaked value
    /// can never route an end user to a variant runtime.
    var selectedAgentVariant: ConvosAPI.AgentVariant? {
        get {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return nil }
            guard let data = UserDefaults.standard.data(forKey: Constant.selectedAgentVariantKey) else { return nil }
            return try? JSONDecoder().decode(ConvosAPI.AgentVariant.self, from: data)
        }
        set {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: Constant.selectedAgentVariantKey)
                return
            }
            UserDefaults.standard.set(data, forKey: Constant.selectedAgentVariantKey)
        }
    }

    private enum Constant {
        static let debugInjectorEnabledKey: String = "featureFlags.debugInjectorEnabled"
        static let mockCreditsPresetKey: String = "featureFlags.mockCreditsPreset"
        static let selectedAgentVariantKey: String = "featureFlags.selectedAgentVariant"
        static let agentVariantSelectorEnabledKey: String = "featureFlags.agentVariantSelectorEnabled"
    }
}
