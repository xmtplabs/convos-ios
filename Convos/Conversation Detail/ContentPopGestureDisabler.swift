import SwiftUI
import UIKit

/// Suspends iOS 26's full-screen interactive pop while the host screen is
/// visible, restoring it on the way out. The system pop is a second
/// recognizer beside the classic edge swipe; on the conversation screen a
/// mid-content horizontal drag would otherwise start the back transition
/// and fight the transcript's swipe-to-reply. (The old conversation pager's
/// horizontal scroll used to claim those drags implicitly.)
///
/// Embedded as a zero-size background view: the hosted controller resolves
/// the navigation controller through the responder chain and rides UIKit's
/// appearance callbacks, which fire on every push/pop - unlike a one-shot
/// introspection, which the system's own gesture management can outlive.
struct ContentPopGestureDisabler: UIViewControllerRepresentable {
    final class Controller: UIViewController {
        /// Captured on appear: `navigationController` resolves through the
        /// parent chain, which is already torn down by `viewWillDisappear`.
        private weak var managedNavigationController: UINavigationController?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            managedNavigationController = navigationController
            navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Re-assert after the transition settles; the system can
            // re-enable the recognizer as part of its own bookkeeping.
            navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            managedNavigationController?.interactiveContentPopGestureRecognizer?.isEnabled = true
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = false
    }
}
