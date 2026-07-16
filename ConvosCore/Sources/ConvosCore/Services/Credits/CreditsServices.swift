import Foundation
import GRDB

/// Process-wide accessor for the active `CreditsServiceProtocol`. Wires the
/// real backend service to the app's database + API client at startup via
/// `configure(...)`; falls back to `MockCreditsService` when the
/// non-production debug toggle is off or `configure(...)` hasn't run yet
/// (preview / test contexts).
public enum CreditsServices {
    /// Real backend service, constructed once at app start once the database
    /// and API client are available. Held nonisolated(unsafe) because the
    /// reference is set once during `ConvosClient.client(...)` before any
    /// caller can race on read; the underlying service handles its own
    /// concurrency.
    nonisolated(unsafe) private static var backendService: BackendCreditsService?

    public static var shared: any CreditsServiceProtocol {
        // Short-circuit to the mock when no backend service has been wired —
        // `useRealBackend` reads `ConfigManager.shared.currentEnvironment`,
        // which `fatalError`s if `ConfigManager.configure(overrides:)` has
        // not run. SwiftUI previews and unit tests that touch
        // `CreditsServices.shared` before the full app boot would otherwise
        // crash, contradicting the documented preview/test fallback above.
        guard let backendService else { return MockCreditsService.shared }
        return useRealBackend ? backendService : MockCreditsService.shared
    }

    /// Wire the real backend service to the database + API client. Called
    /// once from `ConvosClient.client(...)`. Safe to call before the debug
    /// toggle resolves to "real" — the service is built eagerly so flipping
    /// the toggle later picks it up without a relaunch.
    public static func configure(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        apiClient: any ConvosAPIClientProtocol
    ) {
        backendService = BackendCreditsService(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            apiClient: apiClient
        )
    }

    /// Account-deletion fence; see `CreditBalanceWriter.beginAccountWipe()`.
    /// Reaches the backend service directly rather than through `shared` so
    /// the fence runs even when the debug toggle points `shared` at the mock
    /// (the real writer is the only thing that writes `credit_balance`).
    /// Callers must pair it with `endAccountWipe()` in a `defer` around the
    /// row deletion.
    public static func beginAccountWipe() async {
        await backendService?.beginAccountWipe()
    }

    /// Second half of the fence; synchronous so wipe paths can `defer` it
    /// and a failed wipe can't leave credits refresh permanently disabled.
    public static func endAccountWipe() {
        backendService?.endAccountWipe()
    }

    public static var useRealBackend: Bool {
        resolveUseRealBackend(
            environment: ConfigManager.shared.currentEnvironment,
            defaults: .standard
        )
    }

    /// Testable core of `useRealBackend`.
    ///
    /// Do NOT gate the stored override on `#if DEBUG` here. ConvosCore is a
    /// Swift package, and Xcode compiles package dependencies in the
    /// package's *release* configuration for any app build configuration
    /// not named exactly "Debug" — this project runs with "Dev" / "Local",
    /// so a `#if DEBUG` in this file is inactive even in simulator runs
    /// (unlike in app-target files, where the xcconfigs define DEBUG).
    /// That made the Debug-menu toggle's stored value silently ignored:
    /// it re-defaulted to ON every launch. Gate at runtime instead:
    /// production always short-circuits to the real backend, and the only
    /// writer of the override is the Debug menu, which is reachable in
    /// internal (dev/local) builds only.
    static func resolveUseRealBackend(environment: AppEnvironment, defaults: UserDefaults) -> Bool {
        if environment.isProduction { return true }
        if let stored = defaults.object(forKey: Constant.useRealBackendKey) as? Bool {
            return stored
        }
        // Default ON: anyone who never touched the toggle gets real
        // backend credits, including TestFlight dev builds.
        return true
    }

    public static func setUseRealBackend(_ value: Bool) {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        UserDefaults.standard.set(value, forKey: Constant.useRealBackendKey)
    }

    enum Constant {
        /// Versioned key (v2): the original `creditsServices.useRealBackend`
        /// key accumulated stale writes during the eras when the setter
        /// persisted but the gate ignored the stored value (see the doc
        /// comment on `resolveUseRealBackend`). Those stale off values would
        /// have silently flipped TestFlight testers to mock credits once the
        /// gate started honoring them. The old key is intentionally never
        /// read - only deliberate toggles made after the fix persist under v2.
        static let useRealBackendKey: String = "creditsServices.useRealBackend.v2"
    }
}
