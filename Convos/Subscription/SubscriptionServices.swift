import ConvosCore
import Foundation

enum SubscriptionServices {
    static var shared: any SubscriptionServiceProtocol {
        useRealStoreKit ? StoreKitSubscriptionService.shared : MockSubscriptionService.shared
    }

    static var useRealStoreKit: Bool {
        let environment = ConfigManager.shared.currentEnvironment
        if environment.isProduction { return true }
        if let stored = UserDefaults.standard.object(forKey: Constant.useRealStoreKitKey) as? Bool {
            return stored
        }
        return environment.buildEnvironment == .distribution
    }

    static func setUseRealStoreKit(_ value: Bool) {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        UserDefaults.standard.set(value, forKey: Constant.useRealStoreKitKey)
    }

    enum Constant {
        static let useRealStoreKitKey: String = "subscriptionServices.useRealStoreKit"
    }
}
