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

    /// On by default on internal builds, off by default in production --
    /// gates the model picker on an agent's contact card. Reachable in every
    /// environment, same posture as the flags above: the switch is a real
    /// product control meant to be dogfooded on a production build, not a dev
    /// affordance. Dev and Local carry the row without anyone opting in, so
    /// the feature is exercised by default where it is being built; production
    /// stays default-off, and with it the catalogue read, so an agent nobody
    /// is switching is never asked what it can run.
    ///
    /// The default only applies while nothing is stored: an explicit toggle
    /// from either debug menu is honoured in both directions, so turning it
    /// off on a dev build stays off across launches.
    var isAgentModelPickerEnabled: Bool {
        get {
            access(keyPath: \.isAgentModelPickerEnabled)
            if let stored = UserDefaults.standard.object(
                forKey: Constant.agentModelPickerEnabledKey
            ) as? Bool {
                return stored
            }
            return ConfigManager.shared.currentEnvironment.isInternalBuild
        }
        set {
            withMutation(keyPath: \.isAgentModelPickerEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.agentModelPickerEnabledKey)
            }
        }
    }

    /// Off by default -- gates the on-device relay UI for connecting an
    /// external agent. Reachable from both debug menus in every environment.
    var agentRelayEnabled: Bool {
        get {
            access(keyPath: \.agentRelayEnabled)
            return UserDefaults.standard.bool(forKey: Constant.agentRelayEnabledKey)
        }
        set {
            withMutation(keyPath: \.agentRelayEnabled) {
                UserDefaults.standard.set(newValue, forKey: Constant.agentRelayEnabledKey)
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
        static let xmtpBidiStreamsEnabledKey: String = "featureFlags.xmtpBidiStreamsEnabled"
        static let spaceShareEnabledKey: String = "featureFlags.spaceShareEnabled"
        static let webInspectorEnabledKey: String = "featureFlags.webInspectorEnabled"
        static let agentRelayEnabledKey: String = "featureFlags.agentRelayEnabled"
        static let agentModelPickerEnabledKey: String = "featureFlags.agentModelPickerEnabled"
    }
}
