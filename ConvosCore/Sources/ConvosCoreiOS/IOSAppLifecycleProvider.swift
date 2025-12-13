#if canImport(UIKit)
import ConvosCore
import Foundation
import UIKit

/// iOS implementation of app lifecycle provider using UIApplication notifications.
public struct IOSAppLifecycleProvider: AppLifecycleProviding {
    public init() {}

    public var didEnterBackgroundNotification: Notification.Name {
        UIApplication.didEnterBackgroundNotification
    }

    public var willEnterForegroundNotification: Notification.Name {
        UIApplication.willEnterForegroundNotification
    }

    public var didBecomeActiveNotification: Notification.Name {
        UIApplication.didBecomeActiveNotification
    }

    @MainActor
    public var currentState: AppState {
        switch UIApplication.shared.applicationState {
        case .active:
            return .active
        case .inactive:
            return .inactive
        case .background:
            return .background
        @unknown default:
            return .inactive
        }
    }
}
#endif
