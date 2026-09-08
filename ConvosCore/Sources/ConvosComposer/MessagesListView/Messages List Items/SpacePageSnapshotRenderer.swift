#if canImport(UIKit)
import ConvosCore
import ConvosLogging
import UIKit
import WebKit

/// Draws a Space link's card picture from the live page.
///
/// A Space page publishes no `og:image`, and a file committed beside it would
/// be a photograph of one moment in a document the agent rewrites all day. The
/// page itself is the only thing that is always current, so the card shows the
/// page: loaded off-screen at phone width, captured across the top, and handed
/// back on the next card that asks for it.
///
/// Freshness is stale-while-revalidate. A card shows whatever was captured
/// last, immediately, and a capture older than `refreshInterval` starts a new
/// one behind it - so a page that changed shows its old picture for one appearance
/// rather than an empty slot for every appearance.
@MainActor
public final class SpacePageSnapshotRenderer {
    public static let shared: SpacePageSnapshotRenderer = SpacePageSnapshotRenderer()

    /// Laid out at a phone's size so the page settles into the same responsive
    /// layout the Home shows it in, then captured across the top at the card's
    /// aspect. Laying out at the capture height instead would hand the page a
    /// 200pt viewport, which is not a shape it is ever asked to render at.
    private static let layoutSize: CGSize = CGSize(width: 390.0, height: 844.0)
    private static let captureAspectRatio: CGFloat = 1.91
    private static var captureRect: CGRect {
        CGRect(
            x: 0.0,
            y: 0.0,
            width: layoutSize.width,
            height: (layoutSize.width / captureAspectRatio).rounded()
        )
    }

    /// `takeSnapshot` re-rasterizes the render tree to this width, so text and
    /// CSS stay vector-crisp rather than being an upscaled bitmap.
    private static let snapshotOutputWidth: CGFloat = 780.0

    private static let cacheKeyPrefix: String = "space-page-snapshot-v1-"
    private static let loadTimeout: TimeInterval = 15.0
    /// How long a capture is trusted before a card showing it also starts a
    /// fresh one behind it.
    private static let refreshInterval: TimeInterval = 300.0
    /// Longest wait for the page's own script to put something inside the root
    /// element. A Space page is client-rendered: navigation finishing means the
    /// shell arrived, not that there is anything to photograph yet.
    private static let contentTimeout: TimeInterval = 8.0
    private static let contentPollInterval: TimeInterval = 0.15
    /// Breathing room after the root fills so WebKit paints what just mounted.
    private static let paintDelay: TimeInterval = 0.4

    /// Reports whether the page's own render has produced anything yet.
    private static let readinessScript: String = """
    (function() {
        var root = document.getElementById('space-root');
        if (!root) { return false; }
        return root.childElementCount > 0;
    })();
    """

    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private var lastCapturedAt: [String: Date] = [:]

    private init() {}

    // MARK: - API

    /// The last capture of this page, if there is one. Synchronous so a cell
    /// can draw its picture on the first layout rather than a frame later.
    public func cachedSnapshot(for url: URL, appearance: UIUserInterfaceStyle) -> UIImage? {
        ImageCache.shared.image(for: Self.cacheKey(for: url, appearance: appearance))
    }

    /// The picture for this page, capturing one if there is nothing cached.
    ///
    /// Returns the cached capture straight away when there is one. If it has
    /// aged past `refreshInterval` a new capture starts behind the return, and
    /// the next card to ask gets the newer picture.
    public func snapshot(for url: URL, appearance: UIUserInterfaceStyle) async -> UIImage? {
        let key = Self.cacheKey(for: url, appearance: appearance)

        if let cached = await ImageCache.shared.imageAsync(for: key) {
            if Self.isStale(lastCapturedAt[key]) {
                startCapture(url: url, appearance: appearance, key: key)
            }
            return cached
        }

        return await startCapture(url: url, appearance: appearance, key: key).value
    }

    @discardableResult
    private func startCapture(
        url: URL,
        appearance: UIUserInterfaceStyle,
        key: String
    ) -> Task<UIImage?, Never> {
        if let existing = inflight[key] { return existing }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            let image = await render(url: url, appearance: appearance)
            if let image {
                ImageCache.shared.cacheImage(image, for: key, storageTier: .cache)
                lastCapturedAt[key] = Date()
            }
            inflight[key] = nil
            return image
        }
        inflight[key] = task
        return task
    }

    private static func isStale(_ capturedAt: Date?) -> Bool {
        // Nothing recorded means the capture predates this launch, which is
        // reason enough to take a fresh one behind the cached picture.
        guard let capturedAt else { return true }
        return Date().timeIntervalSince(capturedAt) > refreshInterval
    }

    static func cacheKey(for url: URL, appearance: UIUserInterfaceStyle) -> String {
        cacheKeyPrefix + url.absoluteString + "-" + (appearance == .dark ? "dark" : "light")
    }

    // MARK: - Rendering

    private func render(url: URL, appearance: UIUserInterfaceStyle) async -> UIImage? {
        guard let window = Self.offscreenWindow() else {
            Log.error("SpacePageSnapshotRenderer: no offscreen window; skipping capture")
            return nil
        }

        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: Self.layoutSize),
            configuration: WKWebViewConfiguration()
        )
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = true
        webView.isUserInteractionEnabled = false
        // Decides what `prefers-color-scheme` resolves to inside the page,
        // which the WebView's own traits drive whether or not it is on screen.
        webView.overrideUserInterfaceStyle = appearance
        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        guard await load(url: url, in: webView) else { return nil }
        guard await waitForContent(in: webView) else {
            Log.error("SpacePageSnapshotRenderer: page never rendered: \(url.host() ?? "?")")
            return nil
        }
        await Self.sleep(seconds: Self.paintDelay)

        return await capture(from: webView)
    }

    private func load(url: URL, in webView: WKWebView) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let delegate = SnapshotNavigationDelegate { success in
                continuation.resume(returning: success)
            }
            objc_setAssociatedObject(webView, &Self.delegateAssocKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.navigationDelegate = delegate
            webView.load(URLRequest(url: url))

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout) { [weak delegate, weak webView] in
                if delegate?.finish(success: false) == true {
                    Log.error("SpacePageSnapshotRenderer: load timed out")
                    webView?.stopLoading()
                }
            }
        }
    }

    /// Waits for the page's script to mount something. Navigation finishing
    /// only means the shell HTML arrived; the shell is an empty root element.
    private func waitForContent(in webView: WKWebView) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.contentTimeout)
        while Date() < deadline {
            if await Self.evaluateReadiness(in: webView) { return true }
            await Self.sleep(seconds: Self.contentPollInterval)
        }
        return false
    }

    private static func evaluateReadiness(in webView: WKWebView) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            webView.evaluateJavaScript(readinessScript) { result, _ in
                continuation.resume(returning: (result as? Bool) ?? false)
            }
        }
    }

    private func capture(from webView: WKWebView) async -> UIImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = Self.captureRect
        configuration.snapshotWidth = NSNumber(value: Double(Self.snapshotOutputWidth))

        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    Log.error("SpacePageSnapshotRenderer: snapshot failed: \(error)")
                }
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Offscreen host

    /// A WebView only paints while it is in a window, so captures happen in one
    /// parked far off-screen. Hiding it or zeroing its alpha would let UIKit
    /// skip the rendering this exists to get.
    private static func offscreenWindow() -> UIWindow? {
        if let existing = sharedOffscreenWindow { return existing }
        guard !ComposerHostContext.isAppExtension else { return nil }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState != .unattached }
        guard let scene else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(
            x: -100_000.0,
            y: -100_000.0,
            width: layoutSize.width,
            height: layoutSize.height
        )
        window.windowLevel = .normal - 1
        window.isUserInteractionEnabled = false
        window.isHidden = false
        sharedOffscreenWindow = window
        return window
    }

    private static var sharedOffscreenWindow: UIWindow?
    private nonisolated(unsafe) static var delegateAssocKey: UInt8 = 0

    private static func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Reports load completion exactly once, whichever way it ends.
private final class SnapshotNavigationDelegate: NSObject, WKNavigationDelegate {
    private var completion: ((Bool) -> Void)?

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    /// Returns whether this call was the one that finished the load.
    @discardableResult
    func finish(success: Bool) -> Bool {
        guard let completion else { return false }
        self.completion = nil
        completion(success)
        return true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        finish(success: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        finish(success: false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        finish(success: false)
    }
}
#endif
