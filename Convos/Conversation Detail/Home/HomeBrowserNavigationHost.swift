import SwiftUI
import UIKit

/// Hosts the Home and the pages browsed from it in a real navigation controller.
///
/// A SwiftUI `NavigationStack` cannot do this job. Nested inside a pushed
/// destination it disturbs the stack it sits in: the parent's next push is
/// swallowed, and the conversation reads as deselected for a beat - which takes
/// the conversation indicator away and brings the root tab bar back, because
/// `MainTabView` drives both off `isConversationSelected`. A `UINavigationController`
/// nests without any of that; to the SwiftUI stack above it, this is one opaque view.
///
/// What it buys, none of which is worth reimplementing: the push and pop
/// animation, the back semantics, and the interactive edge swipe.
///
/// The pages live *below* the conversation sheet and inside the conversation
/// screen, so browsing never leaves the conversation: the indicator stays above
/// and the sheet stays up, because neither is inside this host.
struct HomeBrowserNavigationHost: UIViewControllerRepresentable {
    /// The pages open, root excluded. Two-way: pushes are driven by writing to
    /// this, and a pop the user performs writes back.
    @Binding var entries: [HomeBrowserEntry]
    /// The Home surface, which is the stack's root and is never popped.
    var root: () -> AnyView
    /// A browsed page.
    var page: (HomeBrowserEntry) -> AnyView

    func makeUIViewController(context: Context) -> UINavigationController {
        let rootController: UIHostingController = HomeBrowserNavigationHost.hostingController(for: root())
        let navigation = UINavigationController(rootViewController: rootController)
        // The conversation's own top bar is the one on screen; this stack is
        // chrome-less and exists only for its navigation behaviour.
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.view.backgroundColor = .clear
        navigation.delegate = context.coordinator
        // Hiding the bar switches the edge-swipe pop off, so hand it a delegate
        // that turns it back on for any page above the root. Without this the
        // gesture the whole exercise is for would not fire.
        navigation.interactivePopGestureRecognizer?.delegate = context.coordinator
        navigation.interactivePopGestureRecognizer?.isEnabled = true
        context.coordinator.navigation = navigation
        return navigation
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        context.coordinator.entries = $entries
        // The root hosts live SwiftUI state - the sheet's coverage becomes the
        // page's bottom inset - so it is refreshed rather than built once.
        (navigation.viewControllers.first as? UIHostingController<AnyView>)?.rootView = root()

        let hosted: Int = max(navigation.viewControllers.count - 1, 0)
        guard hosted != entries.count else { return }

        if entries.count > hosted {
            for entry in entries.suffix(entries.count - hosted) {
                navigation.pushViewController(
                    HomeBrowserNavigationHost.hostingController(for: page(entry)),
                    animated: true
                )
            }
        } else {
            // `entries.count` counts pages; the root sits at index 0, so the
            // controller to return to is at exactly that index.
            let target: UIViewController = navigation.viewControllers[entries.count]
            navigation.popToViewController(target, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(entries: $entries)
    }

    private static func hostingController(for view: AnyView) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: view)
        // The pages paint their own surfaces; an opaque host background would
        // show as a flash of white during the push.
        controller.view.backgroundColor = .clear
        // The safe area is deliberately left intact. The Home reads its top inset
        // to offset the web content below the floating top bar, so clearing the
        // regions here does not free the page up - it hides its first line under
        // the chrome.
        return controller
    }

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
        var entries: Binding<[HomeBrowserEntry]>
        weak var navigation: UINavigationController?

        init(entries: Binding<[HomeBrowserEntry]>) {
            self.entries = entries
        }

        /// Writes a pop the user performed - a back swipe - back into the path.
        ///
        /// Only ever shortens it. A push originates from the binding, so echoing
        /// one back would be reporting news the state already has.
        func navigationController(
            _ navigationController: UINavigationController,
            didShow viewController: UIViewController,
            animated: Bool
        ) {
            let hosted: Int = max(navigationController.viewControllers.count - 1, 0)
            guard hosted < entries.wrappedValue.count else { return }
            entries.wrappedValue = Array(entries.wrappedValue.prefix(hosted))
        }

        /// The edge swipe is only meaningful above the root; at the root the
        /// conversation's own back gesture should keep it.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigation?.viewControllers.count ?? 0) > 1
        }
    }
}
