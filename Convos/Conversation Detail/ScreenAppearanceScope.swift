import SwiftUI
import UIKit

/// Applies an appearance style to the pushed screen's own view controller,
/// for the surfaces that resolve against the UIKit trait collection rather
/// than SwiftUI's `colorScheme` environment: the transcript's collection view
/// and its cells, glass and material effects, and the keyboard.
///
/// `preferredColorScheme` styles the same surfaces, but it resolves at the
/// window: the screen underneath renders in the pushed screen's scheme for as
/// long as the pop animation runs, because the preference only lifts once the
/// popped view is torn down. A trait override belongs to one controller's
/// subtree, so the screen behind it keeps its own appearance throughout, and
/// the override leaves with the controller it was set on.
///
/// Embedded as a zero-size background view, the way `ContentPopGestureDisabler`
/// is: the hosted controller resolves the screen through the parent chain and
/// rides UIKit's appearance callbacks.
struct ScreenAppearanceScope: UIViewControllerRepresentable {
    let style: UIUserInterfaceStyle

    final class Controller: UIViewController {
        var style: UIUserInterfaceStyle = .unspecified {
            didSet {
                guard style != oldValue else { return }
                applyStyle()
            }
        }

        /// The controller the style was last set on, so it can be handed its
        /// own appearance back. Captured because the parent chain is gone by
        /// the time this controller is removed.
        private weak var styledController: UIViewController?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyStyle()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyStyle()
        }

        /// The controller that owns the whole screen, so every surface in it
        /// resolves against the override and the override leaves with the
        /// screen.
        ///
        /// Pushed hosts are the controller the navigation stack pushed. A
        /// modally presented host has no such ancestor: its parent chain ends
        /// at the controller the presentation put on screen - the sheet's
        /// content controller - and styling anything below that leaves the rest
        /// of the sheet resolving against the presenting scheme. Hosts that are
        /// neither keep the nearest ancestor, which still keeps the override
        /// off the window.
        private var screenController: UIViewController? {
            let ancestors = sequence(first: self as UIViewController) { $0.parent }
            var root: UIViewController = self
            for ancestor in ancestors {
                if ancestor.parent is UINavigationController { return ancestor }
                root = ancestor
            }
            // `presentingViewController` is non-nil for a presented controller
            // and for its children, so the end of the parent chain is what
            // distinguishes the presented screen itself from a wrapper inside
            // it. Nil there means nothing presented this host - the chain ends
            // at the window's root - and the override stays where it was.
            if root !== self, root.presentingViewController != nil { return root }
            return parent
        }

        private func applyStyle() {
            guard let screen = screenController else { return }
            if let styledController, styledController !== screen {
                styledController.overrideUserInterfaceStyle = .unspecified
            }
            screen.overrideUserInterfaceStyle = style
            styledController = style == .unspecified ? nil : screen
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.style = style
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.style = style
    }
}
