import Foundation
import UIKit

extension UIView {
    func superview<T>(of type: T.Type) -> T? {
        superview as? T ?? superview.flatMap { $0.superview(of: type) }
    }

    func subview<T>(of type: T.Type) -> T? {
        subviews.compactMap { $0 as? T ?? $0.subview(of: type) }.first
    }
}

extension UIViewController {
    func topMostViewController() -> UIViewController {
        guard let presentedViewController else { return self }

        if let navigationViewController = presentedViewController as? UINavigationController {
            if let visibleViewController = navigationViewController.visibleViewController {
                return visibleViewController.topMostViewController()
            } else {
                return navigationViewController
            }
        }

        if let tabBarViewController = presentedViewController as? UITabBarController {
            if let selectedViewController = tabBarViewController.selectedViewController {
                return selectedViewController.topMostViewController()
            }

            return tabBarViewController
        }

        return presentedViewController.topMostViewController()
    }
}

extension UIApplication {
    /// The top-most view controller of the active UI. Scoped to the
    /// foreground-active window scene's key window so multi-window contexts
    /// (iPad split view / Stage Manager) resolve the window the user is
    /// actually interacting with; falls back to the first window of any
    /// connected scene when no foreground-active key window exists (e.g.
    /// during scene transitions).
    func topMostViewController() -> UIViewController? {
        let windowScenes = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let activeScenes = windowScenes.filter { $0.activationState == .foregroundActive }
        let window: UIWindow? = activeScenes.compactMap(\.keyWindow).first
            ?? activeScenes.flatMap(\.windows).first
            ?? windowScenes.flatMap(\.windows).first
        return window?.rootViewController?.topMostViewController()
    }
}
