import ConvosCore
import Foundation

enum CreditsServices {
    static var shared: any CreditsServiceProtocol {
        useRealBackend ? BackendCreditsService.shared : MockCreditsService.shared
    }

    static var useRealBackend: Bool {
        if ConfigManager.shared.currentEnvironment.isProduction { return true }
        return UserDefaults.standard.bool(forKey: Constant.useRealBackendKey)
    }

    static func setUseRealBackend(_ value: Bool) {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        UserDefaults.standard.set(value, forKey: Constant.useRealBackendKey)
    }

    enum Constant {
        static let useRealBackendKey: String = "creditsServices.useRealBackend"
    }
}
