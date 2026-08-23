import ConvosCore
import Foundation

@MainActor @Observable
final class FeatureFlags {
    static let shared: FeatureFlags = FeatureFlags()

    // Every flag here is a computed property over UserDefaults, and the
    // Observable macro only instruments stored properties. Each accessor
    // therefore registers with the observation registrar by hand --
    // `access(keyPath:)` in get, `withMutation(keyPath:)` around the write
    // -- so views whose bodies read a flag (for example the debug menu's
    // dependent rows) re-evaluate as soon as it is toggled. Without the
    // registrar calls a flip only shows up after the view is rebuilt for
    // some other reason.

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
            access(keyPath: \.isDebugInjectorEnabled)
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return false }
            return UserDefaults.standard.bool(forKey: Constant.debugInjectorEnabledKey)
        }
        set {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
            withMutation(keyPath: \.isDebugInjectorEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.debugInjectorEnabledKey)
            }
        }
    }

    /// Off by default -- gates the dev-only agent variant selector that appears
    /// in the make-an-agent composer. Toggle from App Settings -> Debug. Hard-
    /// locked off in production so the selector can never surface for end users.
    var isAgentVariantSelectorEnabled: Bool {
        get {
            access(keyPath: \.isAgentVariantSelectorEnabled)
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return false }
            return UserDefaults.standard.bool(forKey: Constant.agentVariantSelectorEnabledKey)
        }
        set {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
            withMutation(keyPath: \.isAgentVariantSelectorEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.agentVariantSelectorEnabledKey)
            }
            // Clear any cached selection when the feature is turned off so a
            // stale variant can't resurface on re-enable. Reads are already
            // gated on this flag; clearing keeps the persisted state honest too.
            if !newValue {
                selectedAgentVariant = nil
            }
        }
    }

    /// Gates the per-conversation agent participation control ("Listen"):
    /// Speak freely / Listen mode / Paused. Toggle from App Settings -> Debug
    /// in non-production builds, or from the curated prod debug menu in
    /// production. Deliberately not prod-locked like the flags above: the
    /// control is reachable everywhere so Listen can be dogfooded in TestFlight.
    ///
    /// On by default in every build, production included, so the control is
    /// there without anyone having to find a debug menu first. An explicit
    /// toggle in either direction is remembered and wins over the default, so
    /// turning it off from the prod debug menu still sticks.
    var isListenParticipationEnabled: Bool {
        get {
            access(keyPath: \.isListenParticipationEnabled)
            guard let stored = UserDefaults.standard.object(forKey: Constant.listenParticipationEnabledKey) as? Bool else {
                return Self.listenParticipationDefault
            }
            return stored
        }
        set {
            withMutation(keyPath: \.isListenParticipationEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.listenParticipationEnabledKey)
            }
        }
    }

    private static let listenParticipationDefault: Bool = true

    /// Off by default -- opts libxmtp streams onto the shared bidi wire by
    /// exporting `XMTP_BIDI_STREAMS_ENABLED` at launch (see `ConvosApp.init`;
    /// flips take effect on the next launch). Deliberately not prod-locked
    /// like the flags above: the production backend serves the bidi surface
    /// as of 2026-07-15, and this toggle exists to dogfood it there.
    /// Default-off keeps everyone else on the legacy stream path.
    var isXMTPBidiStreamsEnabled: Bool {
        get {
            access(keyPath: \.isXMTPBidiStreamsEnabled)
            return UserDefaults.standard.bool(forKey: Constant.xmtpBidiStreamsEnabledKey)
        }
        set {
            withMutation(keyPath: \.isXMTPBidiStreamsEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.xmtpBidiStreamsEnabledKey)
            }
        }
    }

    /// Off by default -- gates the V2 abilities surfaces (the abilities
    /// catalog list in App Settings and the per-conversation abilities
    /// section), backed by the live abilities backend once enabled (see
    /// `AbilitiesServices.useLiveBackend`, which reports live unconditionally
    /// whenever this flag is on). Toggle from App Settings -> Debug in
    /// non-production builds, or from the curated prod debug menu in
    /// production. Deliberately not prod-locked like most flags above: the
    /// control is reachable everywhere so V2 can be dogfooded in production,
    /// same posture as `isListenParticipationEnabled`. Default stays off in
    /// every environment -- enabling it in production points the client at
    /// whatever the production abilities backend currently serves, which may
    /// lag what dev has.
    ///
    /// Coupled to `AbilitiesServices.useLiveBackend` in both directions so
    /// V2 running against the mock (instead of the live backend) can never
    /// be reached: turning this on forces the live backend on too
    /// (write-time, below). `AbilitiesServices.useLiveBackend`'s getter
    /// enforces the same invariant independent of what is in storage, which
    /// is what actually keeps a value restored from persistence at launch
    /// from resurfacing the invalid combination -- and in production that
    /// getter reports live regardless of storage, so the coupling holds
    /// there without needing a production guard of its own.
    var isAbilitiesV2Enabled: Bool {
        get {
            access(keyPath: \.isAbilitiesV2Enabled)
            return UserDefaults.standard.bool(forKey: Constant.abilitiesV2EnabledKey)
        }
        set {
            withMutation(keyPath: \.isAbilitiesV2Enabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.abilitiesV2EnabledKey)
            }
            if newValue {
                AbilitiesServices.setUseLiveBackend(true)
            }
        }
    }

    /// Off by default -- gates the internal action that copies a Space share
    /// message to the clipboard so another conversation's agent can import
    /// the Space. Deliberately reachable in every environment; production
    /// users opt in from the curated prod debug menu.
    var isSpaceShareEnabled: Bool {
        get {
            access(keyPath: \.isSpaceShareEnabled)
            return UserDefaults.standard.bool(forKey: Constant.spaceShareEnabledKey)
        }
        set {
            withMutation(keyPath: \.isSpaceShareEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.spaceShareEnabledKey)
            }
        }
    }

    /// Off by default -- gates `WKWebView.isInspectable` on the home/space and
    /// browser sub-page web views so Safari Web Inspector can attach to the
    /// `window.convos` bridge. Deliberately reachable in every environment so
    /// the bridge can be inspected on a production build; production users opt
    /// in from the curated prod debug menu. Default-off keeps the web views
    /// closed to the inspector for everyone else.
    var isWebInspectorEnabled: Bool {
        get {
            access(keyPath: \.isWebInspectorEnabled)
            return UserDefaults.standard.bool(forKey: Constant.webInspectorEnabledKey)
        }
        set {
            withMutation(keyPath: \.isWebInspectorEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.webInspectorEnabledKey)
            }
        }
    }

    /// Mock credits/subscription state used by the in-app paywall preview surface
    /// in the Debug menu. Non-production only; defaults to `.plusAmple`.
    var mockCreditsPreset: CreditsStatePreset {
        get {
            access(keyPath: \.mockCreditsPreset)
            let raw = UserDefaults.standard.string(forKey: Constant.mockCreditsPresetKey)
                ?? CreditsStatePreset.plusAmple.rawValue
            return CreditsStatePreset(compatibleRawValue: raw) ?? .plusAmple
        }
        set {
            withMutation(keyPath: \.mockCreditsPreset) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Constant.mockCreditsPresetKey)
            }
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
            access(keyPath: \.selectedAgentVariant)
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return nil }
            guard let data = UserDefaults.standard.data(forKey: Constant.selectedAgentVariantKey) else { return nil }
            return try? JSONDecoder().decode(ConvosAPI.AgentVariant.self, from: data)
        }
        set {
            guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
            withMutation(keyPath: \.selectedAgentVariant) {
                guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                    UserDefaults.standard.removeObject(forKey: Constant.selectedAgentVariantKey)
                    return
                }
                UserDefaults.standard.set(data, forKey: Constant.selectedAgentVariantKey)
            }
        }
    }

    /// The agent variant slug every agent call routes to: the join itself, the
    /// join-status poll, and the participation read and mirror.
    ///
    /// No environment pins a variant today, so this is the dev selector's pick
    /// and the default worker whenever the selector is off or empty. A config
    /// `pinnedAgentVariantSlug` wins outright when an environment does set one,
    /// so that build lands on the same worker no matter what the selector holds.
    ///
    /// A pin is a registry *slug*, not a worker host: the backend builds the
    /// host as `ephemeral-<slug>.convos.fun`, so pinning the host name instead
    /// misses the registry lookup. Either way the variant is stripped on
    /// production by the API client, and an unknown slug degrades to the
    /// default worker rather than failing the join.
    var effectiveAgentVariantSlug: String? {
        if let pinned = ConfigManager.shared.pinnedAgentVariantSlug {
            return pinned
        }
        guard isAgentVariantSelectorEnabled else { return nil }
        return selectedAgentVariant?.slug
    }

    private enum Constant {
        static let debugInjectorEnabledKey: String = "featureFlags.debugInjectorEnabled"
        static let mockCreditsPresetKey: String = "featureFlags.mockCreditsPreset"
        static let selectedAgentVariantKey: String = "featureFlags.selectedAgentVariant"
        static let agentVariantSelectorEnabledKey: String = "featureFlags.agentVariantSelectorEnabled"
        static let listenParticipationEnabledKey: String = "featureFlags.listenParticipationEnabled"
        static let xmtpBidiStreamsEnabledKey: String = "featureFlags.xmtpBidiStreamsEnabled"
        static let abilitiesV2EnabledKey: String = "featureFlags.abilitiesV2Enabled"
        static let spaceShareEnabledKey: String = "featureFlags.spaceShareEnabled"
        static let webInspectorEnabledKey: String = "featureFlags.webInspectorEnabled"
    }
}
