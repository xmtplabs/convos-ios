import SwiftUI
import UIKit

/// Forces an interface style on the conversation sheet, and on nothing else.
///
/// The Agent lane is a dark surface, and its composer's materials resolve against
/// the UIKit trait collection rather than SwiftUI's environment - so the style has
/// to be forced rather than set with `environment(\.colorScheme,)`.
///
/// `preferredColorScheme` is the obvious way to force it and the wrong one here:
/// applied inside a sheet it propagates to the enclosing *window*, so switching to
/// the Agent lane darkened the status bar and the conversation's top bar above the
/// sheet before they settled back. Setting `overrideUserInterfaceStyle` on the
/// sheet's own view controller keeps the trait inside the sheet, where the only
/// views that want it live.
struct SheetInterfaceStyle: UIViewControllerRepresentable {
    var style: UIUserInterfaceStyle

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.apply(style)
    }

    final class Controller: UIViewController {
        private var pendingStyle: UIUserInterfaceStyle = .unspecified

        // Applied as early as the hierarchy allows, and again at every later
        // point one becomes reachable. The style has to be on the sheet before
        // it is on screen: resolved only once the probe had a window, the sheet
        // presented light and turned dark a beat later, which is the flicker
        // this is here to avoid in the first place.
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply(pendingStyle)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply(pendingStyle)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(pendingStyle)
        }

        func apply(_ style: UIUserInterfaceStyle) {
            pendingStyle = style
            guard let sheetRoot, sheetRoot.overrideUserInterfaceStyle != style else { return }
            sheetRoot.overrideUserInterfaceStyle = style
        }

        /// The sheet's own root: the top of the controller hierarchy this probe
        /// is embedded in.
        ///
        /// Taken as the *last* ancestor rather than the first. Walking up and
        /// stopping at the first controller with a `presentingViewController`
        /// looked equivalent and was not: that property is non-nil for any
        /// controller inside a presented hierarchy, not only for the presented
        /// root, so the walk stopped on its first step and forced the trait onto
        /// this zero-size probe - which has no content to style and no children
        /// to inherit it.
        ///
        /// The parent chain is used because it is connected before the sheet has
        /// a window, which is what lets the style be set before the sheet is
        /// visible. Until the probe is attached there is no chain to walk, and
        /// the window's presentation chain answers instead.
        private var sheetRoot: UIViewController? {
            var candidate: UIViewController = self
            while let parent = candidate.parent {
                candidate = parent
            }
            if candidate !== self, candidate.presentingViewController != nil {
                return candidate
            }
            return presentedAncestorInWindow
        }

        /// The deepest presented controller whose view contains this probe, for
        /// the window-based fallback. The containment test keeps the style off
        /// anything presented above the sheet, which this probe is not inside.
        private var presentedAncestorInWindow: UIViewController? {
            guard let window = view.window else { return nil }
            var candidate: UIViewController? = window.rootViewController
            var match: UIViewController?
            while let controller = candidate {
                if controller.presentingViewController != nil,
                   view.isDescendant(of: controller.view) {
                    match = controller
                }
                candidate = controller.presentedViewController
            }
            return match
        }
    }
}

extension ColorScheme {
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark: return .dark
        case .light: return .light
        @unknown default: return .unspecified
        }
    }
}
