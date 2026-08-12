import ConvosComposer
import SwiftUI
import UIKit
import WebKit

/// One popup in the desktop browser stack. Each intercepted navigation pushes a
/// fresh entry; the web view it opened stays frozen behind the new one.
struct DesktopBrowserEntry: Identifiable {
    let id: UUID = UUID()
    let url: URL
}

/// Bridges the UIKit browser popup into the SwiftUI conversation stack. The host
/// renders one of these per `DesktopBrowserEntry` in a `ForEach` placed between
/// `DesktopLayoutView` and `ConversationDrawer`, so each popup sits above the
/// desktop surface and below the chat drawer. Rendering the representable
/// instantiates a real, separate `DesktopBrowserPopupViewController` with its own
/// web view; removing the entry tears that view controller down.
struct DesktopBrowserPopup: UIViewControllerRepresentable {
    let url: URL
    /// Fired when this popup's page requests navigation away from `url`; the host
    /// stacks another popup for it.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }
    /// Called once the popup's close animation completes; the host pops this entry.
    var onClose: () -> Void

    func makeUIViewController(context: Context) -> DesktopBrowserPopupViewController {
        DesktopBrowserPopupViewController(
            url: url,
            onNavigationRequest: onNavigationRequest,
            onClose: onClose
        )
    }

    func updateUIViewController(_ viewController: DesktopBrowserPopupViewController, context: Context) {
        viewController.onNavigationRequest = onNavigationRequest
        viewController.onClose = onClose
    }
}

/// A self-contained browser popup rendered as its own view controller. It fills
/// its host area with a web view clipped into a rounded panel that springs in on
/// appear, and floats a glass circular close button top-trailing inside the safe
/// area. It pins the URL it opened with: any further navigation is intercepted
/// and handed to `onNavigationRequest` so the host stacks a new popup on top,
/// leaving this one frozen on its page. Tapping close springs the panel out and
/// then calls `onClose`, which removes this view controller from the stack.
final class DesktopBrowserPopupViewController: UIViewController {
    var onNavigationRequest: @MainActor (URL) -> Void {
        didSet { webCoordinator.onNavigationRequest = onNavigationRequest }
    }
    var onClose: () -> Void

    private let url: URL
    private let webView: WKWebView
    private let webCoordinator: DesktopBrowserWebCoordinator
    private let backdropView: UIView = UIView()
    private let panelView: UIView = UIView()
    private let closeButtonContainer: UIVisualEffectView
    private var hasAnimatedIn: Bool = false
    private var isDismissing: Bool = false

    init(
        url: URL,
        onNavigationRequest: @escaping @MainActor (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.url = url
        self.onNavigationRequest = onNavigationRequest
        self.onClose = onClose
        self.webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        self.webCoordinator = DesktopBrowserWebCoordinator(onNavigationRequest: onNavigationRequest)
        let glassEffect = UIGlassEffect()
        glassEffect.isInteractive = true
        self.closeButtonContainer = UIVisualEffectView(effect: glassEffect)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureBackdrop()
        configurePanel()
        configureWebView()
        configureCloseButton()
        setHiddenForReveal()
        webCoordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasAnimatedIn else { return }
        hasAnimatedIn = true
        reveal()
    }

    private func configureBackdrop() {
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.backgroundColor = UIColor.black.withAlphaComponent(Constant.backdropAlpha)
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        backdropView.addGestureRecognizer(dismissTap)
        view.addSubview(backdropView)
        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func configurePanel() {
        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.backgroundColor = UIColor(named: "colorBackgroundRaised") ?? .systemBackground
        panelView.clipsToBounds = true
        panelView.layer.cornerRadius = Constant.cornerRadius
        panelView.layer.cornerCurve = .continuous
        panelView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.addSubview(panelView)
        NSLayoutConstraint.activate([
            panelView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Constant.panelTopInset),
            panelView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panelView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func configureWebView() {
        let raisedBackground = UIColor(named: "colorBackgroundRaised") ?? .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = webCoordinator
        webView.uiDelegate = webCoordinator
        webView.isOpaque = false
        webView.backgroundColor = raisedBackground
        webView.scrollView.backgroundColor = raisedBackground
        panelView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: panelView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor)
        ])
    }

    private func configureCloseButton() {
        closeButtonContainer.translatesAutoresizingMaskIntoConstraints = false
        closeButtonContainer.clipsToBounds = true
        closeButtonContainer.layer.cornerRadius = Constant.closeButtonSize / 2
        closeButtonContainer.layer.cornerCurve = .circular

        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: Constant.closeGlyphPointSize, weight: .semibold)
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark", withConfiguration: symbolConfiguration), for: .normal)
        button.tintColor = UIColor(named: "colorTextPrimary") ?? .label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "Close"
        button.accessibilityIdentifier = "desktop-browser-close"
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        closeButtonContainer.contentView.addSubview(button)
        view.addSubview(closeButtonContainer)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: closeButtonContainer.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: closeButtonContainer.contentView.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: closeButtonContainer.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: closeButtonContainer.contentView.trailingAnchor),
            closeButtonContainer.widthAnchor.constraint(equalToConstant: Constant.closeButtonSize),
            closeButtonContainer.heightAnchor.constraint(equalToConstant: Constant.closeButtonSize),
            closeButtonContainer.topAnchor.constraint(equalTo: panelView.topAnchor, constant: Constant.closeButtonInset),
            closeButtonContainer.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -Constant.closeButtonInset)
        ])
    }

    private func setHiddenForReveal() {
        backdropView.alpha = 0
        panelView.alpha = 0
        panelView.transform = CGAffineTransform(scaleX: Constant.hiddenScale, y: Constant.hiddenScale)
        closeButtonContainer.alpha = 0
    }

    private func reveal() {
        UIView.animate(
            withDuration: Constant.revealDuration,
            delay: 0,
            usingSpringWithDamping: Constant.revealDamping,
            initialSpringVelocity: Constant.revealVelocity,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.backdropView.alpha = 1
            self.panelView.alpha = 1
            self.panelView.transform = .identity
            self.closeButtonContainer.alpha = 1
        }
    }

    @objc
    private func closeTapped() {
        guard !isDismissing else { return }
        isDismissing = true
        let onClose = onClose
        UIView.animate(
            withDuration: Constant.dismissDuration,
            delay: 0,
            usingSpringWithDamping: Constant.dismissDamping,
            initialSpringVelocity: 0,
            options: [.curveEaseIn],
            animations: {
                self.backdropView.alpha = 0
                self.panelView.alpha = 0
                self.panelView.transform = CGAffineTransform(scaleX: Constant.hiddenScale, y: Constant.hiddenScale)
                self.closeButtonContainer.alpha = 0
            },
            completion: { _ in
                onClose()
            }
        )
    }

    private enum Constant {
        static let cornerRadius: CGFloat = DesignConstants.CornerRadius.large
        static let panelTopInset: CGFloat = DesignConstants.Spacing.step2x
        static let backdropAlpha: CGFloat = 0.4
        static let closeButtonSize: CGFloat = 44.0
        static let closeButtonInset: CGFloat = DesignConstants.Spacing.step4x
        static let closeGlyphPointSize: CGFloat = 16.0
        static let hiddenScale: CGFloat = 0.92
        static let revealDuration: TimeInterval = 0.45
        static let revealDamping: CGFloat = 0.78
        static let revealVelocity: CGFloat = 0.5
        static let dismissDuration: TimeInterval = 0.3
        static let dismissDamping: CGFloat = 0.9
    }
}

/// Owns the popup web view's navigation policy: it pins the URL the popup opened
/// with and hands any further navigation back to the host so a new popup stacks
/// on top, leaving this web view frozen on its page. Links targeting a new
/// window route the same way. Kept as a separate `NSObject` (WebKit delegate
/// callbacks arrive without main-actor isolation) and retained by the view
/// controller.
private final class DesktopBrowserWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onNavigationRequest: @MainActor (URL) -> Void
    var loadedURL: URL?
    var hasFinishedInitialLoad: Bool = false

    init(onNavigationRequest: @escaping @MainActor (URL) -> Void) {
        self.onNavigationRequest = onNavigationRequest
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        hasFinishedInitialLoad = true
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = DesktopWebNavigation.interceptedURL(
            for: navigationAction,
            loadedURL: loadedURL,
            hasFinishedInitialLoad: hasFinishedInitialLoad
        ) else {
            return .allow
        }
        DesktopWebNavigation.route(url, toHost: onNavigationRequest)
        return .cancel
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            DesktopWebNavigation.route(url, toHost: onNavigationRequest)
        }
        return nil
    }
}

#Preview {
    ZStack {
        Color.colorBackgroundSubtle
            .ignoresSafeArea()
        if let url = URL(string: "https://convos.org") {
            DesktopBrowserPopup(url: url, onClose: {})
                .ignoresSafeArea()
        }
    }
}
