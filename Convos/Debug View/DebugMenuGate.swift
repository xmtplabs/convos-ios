import ConvosCore
import Foundation

/// Runtime gate deciding whether a debug menu is reachable.
///
/// The codebase prefers runtime gates over `#if DEBUG` because `#if DEBUG`
/// does not propagate into SPM packages like `ConvosCore`, so a runtime
/// environment check is used instead.
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
    ///
    /// Reads the observable `DebugMenuFlagStore.shared`, so a view body that
    /// calls this re-evaluates as soon as the flag is toggled from anywhere
    /// (the enable prompt, or the toggle inside the prod debug menu).
    @MainActor
    static func showsProdDebugMenu(for environment: AppEnvironment) -> Bool {
        if !environment.isProduction { return true }
        return DebugMenuFlagStore.shared.isEnabled
    }
}
