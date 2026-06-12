#if canImport(UIKit)
import ConvosCore
import ConvosLogging
import UIKit
import WebKit

@MainActor
public final class HTMLThumbnailRenderer {
    public static let shared: HTMLThumbnailRenderer = HTMLThumbnailRenderer()

    // The on-screen HTML tile is 160pt. We lay the WebView out at exactly
    // that size so the artifact's responsive layout matches the live tile
    // (paired with `width=160` in viewportScript). Output crispness comes
    // from snapshotOutputWidth, not from an oversized frame.
    private static let tileSize: CGSize = CGSize(width: 160, height: 160)
    // WKWebView.takeSnapshot re-rasterizes the render tree to this width
    // (points), producing a 480px @3x image of the 160pt layout. This is a
    // true re-raster - vector text / CSS stay crisp - not a bitmap upscale.
    // @2x devices downscale 480 cleanly; smaller would blur on @3x.
    private static let snapshotOutputWidth: CGFloat = 480.0
    fileprivate static let paintDelay: TimeInterval = 0.5
    private static let loadTimeout: TimeInterval = 15.0
    // v6: WebView frame matches the 160pt tile and takeSnapshot upsamples
    // to 480px via snapshotWidth. v5 laid out at 160 inside a 480 frame, so
    // content only filled the top-left 160x160 of the capture; those
    // thumbnails get re-rendered on demand.
    private static let cacheKeyPrefix: String = "html-thumb-v6-"

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
        guard !ComposerHostContext.isAppExtension else { return nil }
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
            width: tileSize.width,
            height: tileSize.height
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

    public func cachedThumbnail(for attachmentKey: String, appearance: UIUserInterfaceStyle) -> UIImage? {
        ImageCache.shared.image(for: Self.cacheKey(for: attachmentKey, appearance: appearance))
    }

    public func thumbnail(for attachmentKey: String, fileURL: URL, appearance: UIUserInterfaceStyle) async -> UIImage? {
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
            frame: CGRect(origin: .zero, size: Self.tileSize),
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
            let coordinator = LoadCoordinator(
                captureRect: CGRect(origin: .zero, size: Self.tileSize),
                snapshotWidth: Self.snapshotOutputWidth
            ) { [weak webView] result in
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

    // MARK: - Full-page rendering

    // Full-page renders lay the artifact out at a phone-like width and grow
    // the WebView to the whole document height before snapshotting, so the
    // shared image shows the entire page rather than the 160pt tile crop.
    private static let fullPageSize: CGSize = CGSize(width: 390, height: 844)
    // Caps the bitmap: 780px wide at 2x costs roughly 6 MB of memory per
    // 1000pt of height, so 10k pt keeps the peak around 60 MB.
    private static let fullPageMaxHeight: CGFloat = 10_000.0
    // Output pixel width of the stitched image (2x of the 390pt layout).
    private static let fullPagePixelWidth: CGFloat = 780.0
    // Pause after each programmatic scroll so WebKit paints the newly
    // exposed screenful (and any scroll-triggered lazy content mounts)
    // before it is snapshotted.
    private static let fullPageScrollSettle: TimeInterval = 0.35

    private static let fullPageViewportScript: String = """
    (function() {
        var existing = document.querySelectorAll('meta[name="viewport"]');
        for (var i = 0; i < existing.length; i++) {
            existing[i].remove();
        }
        var m = document.createElement('meta');
        m.name = 'viewport';
        m.content = 'width=390, initial-scale=1, viewport-fit=cover';
        (document.head || document.documentElement).appendChild(m);
    })();
    """

    /// Unlike the thumbnail surface script, full-page renders present as a
    /// large surface so the artifact lays out its full UI.
    private static let fullPageSurfaceScript: String = """
    (function() {
        document.documentElement.setAttribute('data-convos-surface', 'large');
    })();
    """

    /// Returns a file URL to the rendered full-page PNG, rendering and
    /// caching it on disk on first request. The Caches location means iOS
    /// reclaims the space under pressure and the render simply reruns.
    /// `basename` becomes the shared file's display name, so pass the
    /// artifact's title-derived name.
    func fullPagePNGURL(
        for attachmentKey: String,
        fileURL: URL,
        appearance: UIUserInterfaceStyle,
        basename: String
    ) async -> URL? {
        let cacheURL = Self.fullPageCacheURL(for: attachmentKey, appearance: appearance, basename: basename)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            return cacheURL
        }

        let inflightKey = "fullpage-png-" + attachmentKey + "-" + Self.appearanceSuffix(for: appearance)
        if let existing = inflightPNG[inflightKey] {
            return await existing.value
        }
        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            guard let image = await self.fullPageImage(for: attachmentKey, fileURL: fileURL, appearance: appearance) else {
                return nil
            }
            return await Self.writePNG(image: image, to: cacheURL)
        }
        inflightPNG[inflightKey] = task
        let result = await task.value
        inflightPNG.removeValue(forKey: inflightKey)
        return result
    }

    private var inflightPNG: [String: Task<URL?, Never>] = [:]

    /// Collision-safe path component for an attachment key: a short
    /// readable sanitized prefix plus a stable FNV-1a hash of the full
    /// key, so long keys that share a prefix cannot collide the way a
    /// plain truncation would.
    nonisolated static func stableKeyComponent(for raw: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let readable: String = sanitizePathComponent(String(raw.prefix(24)))
        return readable + "-" + String(hash, radix: 16)
    }

    private static func fullPageCacheURL(
        for attachmentKey: String,
        appearance: UIUserInterfaceStyle,
        basename: String
    ) -> URL {
        let caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let keyComponent: String = stableKeyComponent(for: attachmentKey) + "-" + appearanceSuffix(for: appearance)
        return caches
            .appendingPathComponent("html-fullpage-v1", isDirectory: true)
            .appendingPathComponent(keyComponent, isDirectory: true)
            .appendingPathComponent(basename + ".png")
    }

    private nonisolated static func sanitizePathComponent(_ raw: String) -> String {
        let allowed: CharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var output: String = ""
        for scalar in raw.unicodeScalars {
            output.append(allowed.contains(scalar) ? Character(scalar) : "_")
        }
        return output.isEmpty ? "attachment" : output
    }

    private static func writePNG(image: UIImage, to url: URL) async -> URL? {
        await Task.detached(priority: .utility) {
            guard let pngData = image.pngData() else {
                Log.error("HTMLThumbnailRenderer: failed to encode full-page PNG")
                return nil
            }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try pngData.write(to: url, options: .atomic)
                return url
            } catch {
                Log.error("HTMLThumbnailRenderer: failed to write full-page PNG: \(error)")
                return nil
            }
        }.value
    }

    /// Renders the entire document as one tall image. Not cached in
    /// `ImageCache` - full-page bitmaps are far too large for it - so
    /// callers should use `fullPagePNGURL`, which caches the encoded PNG
    /// on disk instead.
    func fullPageImage(for attachmentKey: String, fileURL: URL, appearance: UIUserInterfaceStyle) async -> UIImage? {
        let inflightKey = "fullpage-" + attachmentKey + "-" + Self.appearanceSuffix(for: appearance)
        if let existing = inflight[inflightKey] {
            return await existing.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.renderFullPageSnapshot(fileURL: fileURL, appearance: appearance)
        }
        inflight[inflightKey] = task
        let result = await task.value
        inflight.removeValue(forKey: inflightKey)
        return result
    }

    private func renderFullPageSnapshot(fileURL: URL, appearance: UIUserInterfaceStyle) async -> UIImage? {
        guard let window = offscreenWindow else {
            Log.error("HTMLThumbnailRenderer: no offscreen window available; skipping full-page render")
            return nil
        }

        let config = WKWebViewConfiguration()
        let surfaceUserScript = WKUserScript(
            source: Self.fullPageSurfaceScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(surfaceUserScript)
        let viewportUserScript = WKUserScript(
            source: Self.fullPageViewportScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(viewportUserScript)

        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: Self.fullPageSize),
            configuration: config
        )
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = true
        webView.isUserInteractionEnabled = false
        webView.overrideUserInterfaceStyle = appearance

        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        guard await load(fileURL: fileURL, in: webView) else { return nil }
        await Self.sleep(seconds: Self.paintDelay)

        // The WebView stays at viewport size and the document is scrolled
        // one screenful at a time, snapshotting each. Scrolling is what
        // makes WebKit paint each region AND what triggers any lazy,
        // IntersectionObserver-driven sections the artifact runtime mounts
        // on scroll - resized-frame captures, per-rect tile captures, and
        // createPDF all came back blank below the first viewport because
        // that content was never painted (verified empirically on-device).
        let measured: CGFloat = await measureContentHeight(of: webView)
        let height: CGFloat = Self.clampFullPageHeight(measured)
        return await captureScrollingSnapshot(of: webView, height: height)
    }

    private func captureScrollingSnapshot(of webView: WKWebView, height: CGFloat) async -> UIImage? {
        // takeSnapshot multiplies snapshotWidth by the screen scale, so
        // divide it back out to get a deterministic output pixel width.
        let screenScale: CGFloat = max(webView.traitCollection.displayScale, 1)
        let snapshotWidthPoints: CGFloat = Self.fullPagePixelWidth / screenScale
        let viewportHeight: CGFloat = Self.fullPageSize.height

        var tiles: [(image: UIImage, yOffset: CGFloat)] = []
        var offset: CGFloat = 0
        while offset < height {
            // The last screenful is anchored to the document bottom, so it
            // overlaps the previous tile; the overlap draws identical
            // content and stitches seamlessly.
            let scrollY: CGFloat = max(0, min(offset, height - viewportHeight))
            webView.scrollView.contentOffset = CGPoint(x: 0, y: scrollY)
            await Self.sleep(seconds: Self.fullPageScrollSettle)
            guard let tile = await takeSnapshot(of: webView, outputWidth: snapshotWidthPoints) else {
                Log.error("HTMLThumbnailRenderer: full-page tile at \(scrollY)pt failed; aborting")
                return nil
            }
            tiles.append((tile, scrollY))
            offset += viewportHeight
        }
        webView.scrollView.contentOffset = .zero

        let pixelsPerPoint: CGFloat = Self.fullPagePixelWidth / Self.fullPageSize.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let finalSize = CGSize(
            width: Self.fullPagePixelWidth,
            height: (height * pixelsPerPoint).rounded()
        )
        let renderer = UIGraphicsImageRenderer(size: finalSize, format: format)
        return renderer.image { _ in
            for tile in tiles {
                let drawRect = CGRect(
                    x: 0,
                    y: (tile.yOffset * pixelsPerPoint).rounded(),
                    width: Self.fullPagePixelWidth,
                    height: (tile.image.size.height * Self.fullPagePixelWidth / tile.image.size.width).rounded()
                )
                tile.image.draw(in: drawRect)
            }
        }
    }

    private func takeSnapshot(of webView: WKWebView, outputWidth: CGFloat) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let snapshotConfig = WKSnapshotConfiguration()
            snapshotConfig.rect = webView.bounds
            snapshotConfig.snapshotWidth = NSNumber(value: Double(outputWidth))
            snapshotConfig.afterScreenUpdates = true
            webView.takeSnapshot(with: snapshotConfig) { image, error in
                if let error {
                    Log.error("HTMLThumbnailRenderer full-page takeSnapshot failed: \(error)")
                }
                continuation.resume(returning: image)
            }
        }
    }

    private static func clampFullPageHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, fullPageSize.height), fullPageMaxHeight)
    }

    private func load(fileURL: URL, in webView: WKWebView) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let delegate = NavigationCompletionDelegate { success in
                continuation.resume(returning: success)
            }
            objc_setAssociatedObject(webView, &Self.coordinatorAssocKey, delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.navigationDelegate = delegate

            let readAccessURL = fileURL.deletingLastPathComponent()
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout) { [weak delegate, weak webView] in
                if delegate?.finish(success: false) == true {
                    Log.error("HTMLThumbnailRenderer: full-page load timed out")
                    webView?.stopLoading()
                }
            }
        }
    }

    private func measureContentHeight(of webView: WKWebView) async -> CGFloat {
        await withCheckedContinuation { (continuation: CheckedContinuation<CGFloat, Never>) in
            let js = "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"
            webView.evaluateJavaScript(js) { result, error in
                if let error {
                    Log.error("HTMLThumbnailRenderer: full-page height measurement failed: \(error)")
                }
                let value: CGFloat = (result as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
                continuation.resume(returning: value)
            }
        }
    }

    private static func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Minimal navigation delegate that reports load completion exactly once.
/// The full-page render path drives measurement and snapshotting itself, so
/// it only needs to know when the document finished (or failed to) load.
private final class NavigationCompletionDelegate: NSObject, WKNavigationDelegate {
    private var completion: ((Bool) -> Void)?

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        finish(success: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        Log.error("HTMLThumbnailRenderer full-page load failed: \(error)")
        finish(success: false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        Log.error("HTMLThumbnailRenderer full-page provisional load failed: \(error)")
        finish(success: false)
    }

    @discardableResult
    func finish(success: Bool) -> Bool {
        guard let completion else { return false }
        self.completion = nil
        completion(success)
        return true
    }
}

private final class LoadCoordinator: NSObject, WKNavigationDelegate {
    private let completion: (UIImage?) -> Void
    private let captureRect: CGRect
    private let snapshotWidth: CGFloat
    private var hasResumed: Bool = false

    init(captureRect: CGRect, snapshotWidth: CGFloat, completion: @escaping (UIImage?) -> Void) {
        self.captureRect = captureRect
        self.snapshotWidth = snapshotWidth
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        let captureRect = captureRect
        let snapshotWidth = snapshotWidth
        DispatchQueue.main.asyncAfter(deadline: .now() + HTMLThumbnailRenderer.paintDelay) { [weak self, weak webView] in
            guard let self, !self.hasResumed, let webView else {
                self?.resume(image: nil)
                return
            }
            let snapshotConfig = WKSnapshotConfiguration()
            snapshotConfig.rect = captureRect
            // Re-rasterize the 160pt render tree to a 480px image - crisp,
            // not a bitmap upscale - so the tile fills the full capture.
            snapshotConfig.snapshotWidth = NSNumber(value: Double(snapshotWidth))
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
#endif
