import ConvosCore
import ConvosLogging
import UIKit
import WebKit

@MainActor
final class HTMLThumbnailRenderer {
    static let shared: HTMLThumbnailRenderer = HTMLThumbnailRenderer()

    // 480x480 = the 160pt in-group tile rendered at @3x. @2x devices
    // downscale the resulting image cleanly. Larger than necessary
    // wastes work for every thumbnail; smaller would blur on @3x.
    private static let renderSize: CGSize = CGSize(width: 480, height: 480)
    fileprivate static let paintDelay: TimeInterval = 0.5
    private static let loadTimeout: TimeInterval = 15.0
    // v5: render size dropped to 480x480 + viewport pinned to width=160
    // + small-surface attrs stamped before any artifact JS runs. v4
    // thumbnails (720x1200, no viewport / surface hints) get re-
    // rendered on demand.
    private static let cacheKeyPrefix: String = "html-thumb-v5-"

    /// Runs at .atDocumentEnd so the parser has populated <head> with
    /// the artifact's own <meta viewport>. We strip every existing
    /// viewport tag and append ours - last-in-head wins, and removing
    /// first guarantees we are last regardless of how many the artifact
    /// shipped. Injecting at .atDocumentStart would not see the
    /// artifact's tag (parser has not run yet), so the artifact's
    /// static viewport would end up after ours and win.
    private static let viewportScript: String = """
    (function() {
        var existing = document.querySelectorAll('meta[name="viewport"]');
        for (var i = 0; i < existing.length; i++) {
            existing[i].remove();
        }
        var m = document.createElement('meta');
        m.name = 'viewport';
        m.content = 'width=160, initial-scale=1, viewport-fit=cover';
        (document.head || document.documentElement).appendChild(m);
    })();
    """

    /// Pinned at .atDocumentStart so the runtime's surface-detection JS
    /// reads these attributes on first run rather than falling back to
    /// its `innerHeight >= 900` heuristic - which would resolve to
    /// "large" at our 480pt height and re-strip the attrs.
    private static let surfaceScript: String = """
    (function() {
        document.documentElement.setAttribute('data-convos-thumbnail', 'true');
        document.documentElement.setAttribute('data-convos-surface', 'small');
    })();
    """

    private var inflight: [String: Task<UIImage?, Never>] = [:]

    /// Single off-screen `UIWindow` used as the host for every render
    /// pass. We need *a* window so `WKWebView.takeSnapshot` actually
    /// captures painted content (an unattached `WKWebView` snapshots to
    /// blank). Allocating a fresh window per render historically leaked
    /// a `UIWindowScene.keyboardLayoutGuide` reservation on each render
    /// because the scene held onto each window across the lifetime of
    /// the app; reusing one window means the scene sees the single
    /// reservation forever and never accumulates new ones.
    ///
    /// Not `lazy` - a first access during early launch or a background
    /// context would resolve to `nil` and that `nil` would get cached
    /// permanently, sinking every subsequent render. Retry on each
    /// access until a `UIWindowScene` is actually available, then cache.
    private var offscreenWindow: UIWindow? {
        if let existing = _offscreenWindow { return existing }
        let created = Self.makeOffscreenWindow()
        _offscreenWindow = created
        return created
    }
    private var _offscreenWindow: UIWindow?

    private static func makeOffscreenWindow() -> UIWindow? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState != .unattached }
        guard let scene else { return nil }
        let window = UIWindow(windowScene: scene)
        // Park well off-screen rather than `isHidden = true` or
        // `alpha = 0` - UIKit can skip rendering for the latter two,
        // which would defeat the point of having a host window at all.
        window.frame = CGRect(
            x: -100_000.0,
            y: -100_000.0,
            width: renderSize.width,
            height: renderSize.height
        )
        window.windowLevel = .normal - 1
        window.isUserInteractionEnabled = false
        window.isHidden = false
        return window
    }

    static func cacheKey(for attachmentKey: String, appearance: UIUserInterfaceStyle) -> String {
        cacheKeyPrefix + attachmentKey + "-" + appearanceSuffix(for: appearance)
    }

    private static func appearanceSuffix(for appearance: UIUserInterfaceStyle) -> String {
        switch appearance {
        case .dark: return "dark"
        case .light, .unspecified: return "light"
        @unknown default: return "light"
        }
    }

    func cachedThumbnail(for attachmentKey: String, appearance: UIUserInterfaceStyle) -> UIImage? {
        ImageCache.shared.image(for: Self.cacheKey(for: attachmentKey, appearance: appearance))
    }

    func thumbnail(for attachmentKey: String, fileURL: URL, appearance: UIUserInterfaceStyle) async -> UIImage? {
        let cacheKey = Self.cacheKey(for: attachmentKey, appearance: appearance)
        if let cached = await ImageCache.shared.imageAsync(for: cacheKey) {
            return cached
        }

        // Inflight key includes appearance so a concurrent dark-mode request
        // doesn't await a light-mode render (or vice versa).
        let inflightKey = attachmentKey + "-" + Self.appearanceSuffix(for: appearance)
        if let existing = inflight[inflightKey] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            let image = await self.renderSnapshot(fileURL: fileURL, appearance: appearance)
            if let image {
                ImageCache.shared.cacheImage(image, for: cacheKey, storageTier: .cache)
            }
            return image
        }
        inflight[inflightKey] = task
        let result = await task.value
        inflight.removeValue(forKey: inflightKey)
        return result
    }

    /// Renders the file at `fileURL` directly into a `UIImage` via
    /// `WKWebView.takeSnapshot`. The WebView is briefly attached to the
    /// shared off-screen `offscreenWindow` so the snapshot actually
    /// captures painted content (an unattached WebView snapshots blank),
    /// and removed once we have the image. Reusing one host window
    /// across renders avoids the `UIWindowScene.keyboardLayoutGuide`
    /// reservation leak that bit the original one-window-per-render
    /// implementation.
    private func renderSnapshot(fileURL: URL, appearance: UIUserInterfaceStyle) async -> UIImage? {
        guard let window = offscreenWindow else {
            Log.error("HTMLThumbnailRenderer: no offscreen window available; skipping render")
            return nil
        }

        let config = WKWebViewConfiguration()
        let surfaceUserScript = WKUserScript(
            source: Self.surfaceScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(surfaceUserScript)
        let viewportUserScript = WKUserScript(
            source: Self.viewportScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(viewportUserScript)

        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: Self.renderSize),
            configuration: config
        )
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = true
        webView.isUserInteractionEnabled = false
        // Drives `@media (prefers-color-scheme: ...)` resolution inside the
        // loaded HTML - the WebView's traitCollection determines what
        // matchMedia returns regardless of view-hierarchy attachment.
        webView.overrideUserInterfaceStyle = appearance

        window.addSubview(webView)

        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let coordinator = LoadCoordinator(renderSize: Self.renderSize) { [weak webView] result in
                webView?.removeFromSuperview()
                continuation.resume(returning: result)
            }
            // Retain coordinator for the duration of the load via objc association.
            objc_setAssociatedObject(webView, &Self.coordinatorAssocKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
            webView.navigationDelegate = coordinator

            let readAccessURL = fileURL.deletingLastPathComponent()
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)

            // Safety net: if the load never finishes or fails, resume with nil so
            // the WebView is released by the surrounding closure rather than
            // living forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout) { [weak coordinator, weak webView] in
                coordinator?.resumeIfNeeded(webView: webView, image: nil, reason: "load timed out")
            }
        }
    }

    private nonisolated(unsafe) static var coordinatorAssocKey: UInt8 = 0
}

private final class LoadCoordinator: NSObject, WKNavigationDelegate {
    private let completion: (UIImage?) -> Void
    private let renderSize: CGSize
    private var hasResumed: Bool = false

    init(renderSize: CGSize, completion: @escaping (UIImage?) -> Void) {
        self.renderSize = renderSize
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        let renderSize = renderSize
        DispatchQueue.main.asyncAfter(deadline: .now() + HTMLThumbnailRenderer.paintDelay) { [weak self, weak webView] in
            guard let self, !self.hasResumed, let webView else {
                self?.resume(image: nil)
                return
            }
            let snapshotConfig = WKSnapshotConfiguration()
            snapshotConfig.rect = CGRect(origin: .zero, size: renderSize)
            snapshotConfig.afterScreenUpdates = true
            webView.takeSnapshot(with: snapshotConfig) { image, error in
                if let error {
                    Log.error("HTMLThumbnailRenderer takeSnapshot failed: \(error)")
                }
                self.resume(image: image)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        Log.error("HTMLThumbnailRenderer load failed: \(error)")
        resume(image: nil)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        Log.error("HTMLThumbnailRenderer provisional load failed: \(error)")
        resume(image: nil)
    }

    private func resume(image: UIImage?) {
        guard !hasResumed else { return }
        hasResumed = true
        completion(image)
    }

    func resumeIfNeeded(webView: WKWebView?, image: UIImage?, reason: String) {
        guard !hasResumed else { return }
        Log.error("HTMLThumbnailRenderer resuming early: \(reason)")
        // Stop loading so the in-memory WebView releases its network/JS work
        // before the closure releases it.
        webView?.stopLoading()
        resume(image: image)
    }
}
