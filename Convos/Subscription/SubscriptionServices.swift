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
        // Mirror `CreditsServices.useRealBackend`: `buildEnvironment ==
        // .distribution` reports false on TestFlight because TestFlight
        // builds ship `embedded.mobileprovision` and so classify as
        // `.development`. Use the build configuration instead so
        // TestFlight / App Store / Ad-Hoc default to real StoreKit while
        // local Xcode runs default to the mock.
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    static func setUseRealStoreKit(_ value: Bool) {
        guard !ConfigManager.shared.currentEnvironment.isProduction else { return }
        UserDefaults.standard.set(value, forKey: Constant.useRealStoreKitKey)
    }

    enum Constant {
        static let useRealStoreKitKey: String = "subscriptionServices.useRealStoreKit"
    }
}
