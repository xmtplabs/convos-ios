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
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        background(
            ShareSheetPresenter(
                isPresented: isPresented,
                items: items,
                onPresented: onPresented,
                onDismiss: onDismiss
            )
        )
    }
}

private struct ShareSheetPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let items: [Any]
    let onPresented: (() -> Void)?
    let onDismiss: (() -> Void)?

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented else {
            // The binding flipped to false while the sheet is still up (e.g. a
            // backdrop tap dismissing a containing overlay) - tear it down so the
            // activity controller can't outlive its presenter.
            if uiViewController.presentedViewController != nil {
                uiViewController.dismiss(animated: true)
            }
            return
        }
        guard !items.isEmpty, uiViewController.presentedViewController == nil else {
            return
        }

        let activityViewController = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
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
        activityViewController.completionWithItemsHandler = { _, _, _, _ in
            isPresented = false
            onDismiss?()
        }

        // Present on the next runloop tick so it happens outside the SwiftUI update pass.
        DispatchQueue.main.async {
            guard uiViewController.presentedViewController == nil else { return }
            uiViewController.present(activityViewController, animated: true) {
                onPresented?()
            }
        }
    }
}
