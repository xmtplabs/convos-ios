import ConvosCore
import Foundation

enum SubscriptionServices {
    static var shared: any SubscriptionServiceProtocol {
        useRealStoreKit ? StoreKitSubscriptionService.shared : MockSubscriptionService.shared
    }

    static var useRealStoreKit: Bool {
        if ConfigManager.shared.currentEnvironment.isProduction { return true }
        return UserDefaults.standard.bool(forKey: Constant.useRealStoreKitKey)
    }

    static func setUseRealStoreKit(_ value: Bool) {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        UserDefaults.standard.set(value, forKey: Constant.useRealStoreKitKey)
    }

    enum Constant {
        static let useRealStoreKitKey: String = "subscriptionServices.useRealStoreKit"
    }
}
