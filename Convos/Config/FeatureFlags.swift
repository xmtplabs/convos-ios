import ConvosCore
import Foundation

@MainActor @Observable
final class FeatureFlags {
    static let shared: FeatureFlags = FeatureFlags()

    // Reaching a flag in a production build takes two changes, not one, and
    // missing either looks identical from the device: the control just is not
    // there.
    // 1. The flag itself has to read UserDefaults in production rather than
    //    returning false behind an `isProduction` guard, as most below do.
    // 2. `ProdDebugMenuView` has to carry a row for it. That menu is a curated,
    //    hardcoded list, not a render of every flag here, so a flag unlocked in
    //    step 1 is still unreachable until it is listed there. The full
    //    `DebugView` features section is non-production only.

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

    /// Gates the per-conversation agent participation control ("Listen"):
    /// Speak freely / Mentions only / Paused. Toggle from App Settings -> Debug
    /// in non-production builds, or from the curated prod debug menu in
    /// production. Deliberately not prod-locked like the flags above: the
    /// control is reachable everywhere so Listen can be dogfooded in TestFlight.
    ///
    /// The default follows the build: on for the internal Dev/local builds that
    /// ship to TestFlight, off for production, so end users still have to opt in
    /// from the prod debug menu. An explicit toggle in either direction is
    /// remembered and wins over the default.
    var isListenParticipationEnabled: Bool {
        get {
            guard let stored = UserDefaults.standard.object(forKey: Constant.listenParticipationEnabledKey) as? Bool else {
                return Self.listenParticipationDefault
            }
            return stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constant.listenParticipationEnabledKey)
        }
    }

    private static var listenParticipationDefault: Bool {
        !ConfigManager.shared.currentEnvironment.isProduction
    }

    /// Off by default -- opts libxmtp streams onto the shared bidi wire by
    /// exporting `XMTP_BIDI_STREAMS_ENABLED` at launch (see `ConvosApp.init`;
    /// flips take effect on the next launch). Deliberately not prod-locked
    /// like the flags above: the production backend serves the bidi surface
    /// as of 2026-07-15, and this toggle exists to dogfood it there.
    /// Default-off keeps everyone else on the legacy stream path.
    var isXMTPBidiStreamsEnabled: Bool {
        get {
            return UserDefaults.standard.bool(forKey: Constant.xmtpBidiStreamsEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constant.xmtpBidiStreamsEnabledKey)
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
        static let listenParticipationEnabledKey: String = "featureFlags.listenParticipationEnabled"
        static let xmtpBidiStreamsEnabledKey: String = "featureFlags.xmtpBidiStreamsEnabled"
    }
}
