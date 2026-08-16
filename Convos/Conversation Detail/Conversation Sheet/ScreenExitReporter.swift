import SwiftUI
import UIKit

/// Reports that the host screen is leaving the navigation stack, before the pop
/// animates rather than after it has finished.
///
/// SwiftUI has no `onWillDisappear`, and `onDisappear` is too late for anything
/// that needs to animate out alongside the transition - by then the screen is
/// gone. The conversation sheet needs exactly that: it is a presentation over the
/// whole window, so it does not travel with the pop, and left to the system it
/// stays put while the conversation slides away and then blinks out.
///
/// Embedded as a zero-size background view, the same way `ContentPopGestureDisabler`
/// is: the hosted controller resolves the navigation controller through the
/// responder chain and rides UIKit's appearance callbacks.
struct ScreenExitReporter: UIViewControllerRepresentable {
    /// Called once, when the host screen is definitely on its way out.
    var onExit: () -> Void

    final class Controller: UIViewController {
        var onExit: (() -> Void)?
        /// Captured on appear: `navigationController` resolves through the parent
        /// chain, which is already torn down by `viewWillDisappear`.
        private weak var managedNavigationController: UINavigationController?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            managedNavigationController = navigationController
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard isLeavingTheStack else { return }
            guard let coordinator = managedNavigationController?.transitionCoordinator,
                  coordinator.isInteractive else {
                onExit?()
                return
            }
            // An interactive pop can still be abandoned, and reporting on the
            // first millimetre of an edge swipe would take the sheet away and then
            // hand it back when the user changed their mind.
            coordinator.notifyWhenInteractionChanges { [weak self] context in
                guard !context.isCancelled else { return }
                self?.onExit?()
            }
        }

        /// Whether the screen is being popped, as opposed to covered by something
        /// pushed on top of it - which also disappears, and must not be treated as
        /// an exit.
        ///
        /// A pop has already removed the screen from `viewControllers` by the time
        /// this runs, so the test is whether any ancestor of this probe is still on
        /// the stack.
        private var isLeavingTheStack: Bool {
            guard let stack = managedNavigationController?.viewControllers else { return true }
            var candidate: UIViewController? = self
            while let controller = candidate {
                if stack.contains(controller) { return false }
                candidate = controller.parent
            }
            return true
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onExit = onExit
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onExit = onExit
    }
}
