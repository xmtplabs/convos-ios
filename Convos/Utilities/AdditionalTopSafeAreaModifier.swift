import SwiftUI

private struct AdditionalTopSafeAreaModifier: ViewModifier {
    let inset: CGFloat

    func body(content: Content) -> some View {
        content
            .background(AdditionalTopSafeAreaHelper(inset: inset))
    }
}

private struct AdditionalTopSafeAreaHelper: UIViewControllerRepresentable {
    let inset: CGFloat

    func makeUIViewController(context: Context) -> AdditionalTopSafeAreaViewController {
        AdditionalTopSafeAreaViewController(inset: inset)
    }

    func updateUIViewController(_ controller: AdditionalTopSafeAreaViewController, context: Context) {
        controller.updateInset(inset)
    }
}

private final class AdditionalTopSafeAreaViewController: UIViewController {
    private var inset: CGFloat

    init(inset: CGFloat) {
        self.inset = inset
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        applyInset()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyInset()
    }

    func updateInset(_ newInset: CGFloat) {
        inset = newInset
        applyInset()
    }

    private func applyInset() {
        guard let hostingVC = findHostingController() else { return }
        hostingVC.additionalSafeAreaInsets.top = inset
    }

    private func findHostingController() -> UIViewController? {
        var vc: UIViewController? = parent
        while let current = vc {
            if String(describing: type(of: current)).contains("HostingController") {
                return current
            }
            vc = current.parent
        }
        return nil
    }
}

extension View {
    func additionalTopSafeArea(_ inset: CGFloat) -> some View {
        modifier(AdditionalTopSafeAreaModifier(inset: inset))
    }
}
