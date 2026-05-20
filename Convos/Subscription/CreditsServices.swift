import ConvosCore
import Foundation

enum CreditsServices {
    /// Real backend service, constructed once at app start once the database
    /// and API client are available. The mock fallback is used when
    /// `useRealBackend` is off (non-production debug toggle) or when
    /// `configure(...)` hasn't run yet (preview / test contexts).
    nonisolated(unsafe) private static var backendService: BackendCreditsService?

    static var shared: any CreditsServiceProtocol {
        if useRealBackend, let backendService { return backendService }
        return MockCreditsService.shared
    }

    /// Wire the real backend service to the app's database + API client.
    /// Called once from `ConvosApp.init` after `ConvosClient` is constructed.
    /// Safe to call before the debug toggle resolves to "real" — the service
    /// is built eagerly so flipping the toggle later picks it up without a
    /// relaunch.
    static func configure(client: ConvosClient, apiClient: any ConvosAPIClientProtocol) {
        backendService = BackendCreditsService(
            databaseWriter: client.databaseWriter,
            databaseReader: client.databaseReader,
            apiClient: apiClient
        )
    }

    static var useRealBackend: Bool {
        let environment = ConfigManager.shared.currentEnvironment
        if environment.isProduction { return true }
        if let stored = UserDefaults.standard.object(forKey: Constant.useRealBackendKey) as? Bool {
            return stored
        }
        return environment.buildEnvironment == .distribution
    }

    static func setUseRealBackend(_ value: Bool) {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        UserDefaults.standard.set(value, forKey: Constant.useRealBackendKey)
    }

    enum Constant {
        static let useRealBackendKey: String = "creditsServices.useRealBackend"
    }
}
