import ConvosCore
import Foundation

enum SubscriptionServices {
    static var shared: any SubscriptionServiceProtocol {
        useRealStoreKit ? StoreKitSubscriptionService.shared : MockSubscriptionService.shared
    }

    static var useRealStoreKit: Bool {
        let environment = ConfigManager.shared.currentEnvironment
        if environment.isProduction { return true }
        // The UserDefaults override is intentionally DEBUG-only. On
        // Release builds (TestFlight / App Store / Ad-Hoc) we always
        // return the build-config default below so a stored `false`
        // from a previous Debug build on the same device can't quietly
        // pin a TestFlight tester to the mock service — UserDefaults
        // survives reinstalls under the same bundle ID. The Debug menu
        // toggle still works in Debug builds (where it's reachable).
        #if DEBUG
        if let stored = UserDefaults.standard.object(forKey: Constant.useRealStoreKitKey) as? Bool {
            return stored
        }
        return false
        #else
        // TestFlight builds ship `embedded.mobileprovision` and classify
        // as `.development` per buildEnvironment, so we anchor on the
        // build configuration instead: Release == real StoreKit.
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
