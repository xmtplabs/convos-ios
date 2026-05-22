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

    public static var useRealBackend: Bool {
        let environment = ConfigManager.shared.currentEnvironment
        if environment.isProduction { return true }
        if let stored = UserDefaults.standard.object(forKey: Constant.useRealBackendKey) as? Bool {
            return stored
        }
        return environment.buildEnvironment == .distribution
    }

    public static func setUseRealBackend(_ value: Bool) {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        UserDefaults.standard.set(value, forKey: Constant.useRealBackendKey)
    }

    private enum Constant {
        static let useRealBackendKey: String = "creditsServices.useRealBackend"
    }
}
