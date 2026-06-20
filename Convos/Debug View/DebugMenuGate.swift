import ConvosCore
import Foundation

/// Runtime gate deciding whether a debug menu is reachable.
///
/// The codebase prefers runtime gates over `#if DEBUG` because `#if DEBUG`
/// does not propagate into the ConvosCore SPM package, so environment-based
/// runtime checks are the established convention here.
///
/// - Non-production environments keep the full debug experience unconditionally.
/// - Production exposes only the curated `ProdDebugMenuView`, and only when the
///   persistent `DebugMenuFlagStore` toggle has been explicitly enabled.
enum DebugMenuGate {
    /// True when the full (non-prod) debug section should be shown.
    static func showsFullDebugMenu(for environment: AppEnvironment) -> Bool {
        !environment.isProduction
    }

    /// True when the curated prod debug menu should be reachable. In
    /// production this requires the explicit opt-in toggle; in non-prod it is
    /// always available alongside the full menu.
    static func showsProdDebugMenu(for environment: AppEnvironment) -> Bool {
        if !environment.isProduction { return true }
        return DebugMenuFlagStore.isEnabled()
    }

    /// True when the app-wide "debug mode ON" indicator should be visible.
    /// Only meaningful in production, where the menu is opt-in; in non-prod the
    /// debug menu is always present so the indicator would be noise.
    static func showsDebugModeIndicator(for environment: AppEnvironment) -> Bool {
        environment.isProduction && DebugMenuFlagStore.isEnabled()
    }
}
