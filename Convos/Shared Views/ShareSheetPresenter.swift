import SwiftUI
import UIKit

extension View {
    /// Presents the native share sheet (`UIActivityViewController`) directly over
    /// this view when `isPresented` becomes true, with no intermediate SwiftUI
    /// sheet or backdrop. `isPresented` is reset to false when the share sheet is
    /// dismissed; setting it back to false yourself also dismisses a sheet that is
    /// still on screen. Use this for "share over the current screen"; for a share
    /// sheet with a visible backdrop card, present a backdrop view yourself.
    ///
    /// `onPresented` fires once the share sheet has finished animating in - useful
    /// for clearing a caller's loading state that covers the tap-to-share gap.
    func shareSheet(
        isPresented: Binding<Bool>,
        items: [Any],
        onPresented: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        onCompletion: ((UIActivity.ActivityType?, Bool, Error?) -> Void)? = nil
    ) -> some View {
        background(
            ShareSheetPresenter(
                isPresented: isPresented,
                items: items,
                onPresented: onPresented,
                onDismiss: onDismiss,
                onCompletion: onCompletion
            )
        )
    }
}

private struct ShareSheetPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let items: [Any]
    let onPresented: (() -> Void)?
    let onDismiss: (() -> Void)?
    let onCompletion: ((UIActivity.ActivityType?, Bool, Error?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard isPresented else {
            // The binding flipped to false while the sheet is still up (e.g. a
            // backdrop tap dismissing a containing overlay) - tear it down so the
            // activity controller can't outlive its presenter. Only dismiss the
            // activity controller this presenter actually presented: this hidden
            // host view controller can also be the nearest ancestor UIKit picks
            // to attach a sibling SwiftUI `.sheet` to, and blindly dismissing
            // `presentedViewController` would tear that unrelated sheet down.
            if let presented = coordinator.activityViewController,
               uiViewController.presentedViewController === presented {
                uiViewController.dismiss(animated: true)
            }
            coordinator.activityViewController = nil
            return
        }
        guard !items.isEmpty, coordinator.activityViewController == nil else {
            return
        }

        let activityViewController = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        coordinator.activityViewController = activityViewController
        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = uiViewController.view
            popover.sourceRect = CGRect(
                x: uiViewController.view.bounds.midX,
                y: uiViewController.view.bounds.maxY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = .up
        }
        activityViewController.completionWithItemsHandler = { activityType, completed, _, error in
            coordinator.activityViewController = nil
            isPresented = false
            onCompletion?(activityType, completed, error)
            onDismiss?()
        }

        // Present on the next runloop tick so it happens outside the SwiftUI update pass.
        DispatchQueue.main.async {
            // `isPresented` can flip to false before this tick runs (e.g. a
            // backdrop tap dismissing a containing overlay), which clears the
            // coordinator's controller. Bail when that happened so a cancelled
            // share can't still pop a stale sheet a frame later.
            guard coordinator.activityViewController === activityViewController,
                  uiViewController.presentedViewController == nil else { return }
            uiViewController.present(activityViewController, animated: true) {
                onPresented?()
            }
        }
    }

    final class Coordinator {
        var activityViewController: UIActivityViewController?
    }
}
