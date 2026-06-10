#if canImport(UIKit)
import ConvosCore
import ConvosLogging
import SwiftUI
import UIKit
import WebKit

/// Process-wide LRU cache of fully-loaded `WKWebView`s for HTML
/// attachments the user has seen recently. Sits between the thumbnail
/// renderer (which produces the 160 x 160 cell tile) and the
/// `AttachmentPreviewSheet` (which would otherwise spin up a fresh
/// WebView on tap and wait for `didFinish` before content paints). A
/// live borrowed WebView eliminates the visible "thumbnail -> blank web
/// view -> content fade-in" beat on the matched-geometry zoom transition
/// for the most recent few HTML files.
///
/// Memory ceiling is `cacheLimit` WebViews - typically 5 - with strict
/// LRU eviction. When a cell scrolls into view we kick off a prewarm;
/// when an older cell rolls off the front of the cache, its WebView is
/// torn down. The cache never holds more than `cacheLimit` regardless
/// of how many HTML attachments are in the conversation.
///
/// Prewarms are serialised: at most one off-screen `WKWebView` is loading
/// at any time. Spinning up several `WKWebView` instances in parallel
/// during a fast scroll has noticeable CPU + memory cost; queuing keeps
/// us at one concurrent renderer without sacrificing the cache hit rate
/// (the queue still respects the LRU policy on the way in).
@MainActor
public final class HTMLContentPrewarmer {
    public static let shared: HTMLContentPrewarmer = HTMLContentPrewarmer()

    /// Borrowed handoff payload. The caller owns lifetime of the
    /// returned WebView once they take it from the cache - the cache
    /// itself drops its reference.
    public struct PrewarmedContent {
        public let webView: WKWebView
        public let bodyBackgroundColor: Color?
    }

    private static let cacheLimit: Int = 5
    private static let loadTimeout: TimeInterval = 15.0
    /// Mirrors `HTMLThumbnailRenderer.paintDelay` - the WebView paints a
    /// frame after `didFinish` rather than during. Without this the
    /// borrowed WebView would still flash blank for the first frame
    /// after being attached to the sheet's hierarchy.
    private static let paintDelay: TimeInterval = 0.3
    /// Fallback render size used only when the active window scene's
    /// screen bounds aren't available (no foreground-active scene yet).
    /// Picked to match a typical iPhone 17 canvas so the rare fallback
    /// path still produces a useful layout.
    private static let fallbackPrewarmSize: CGSize = CGSize(width: 430, height: 932)

    /// Insertion-ordered LRU: most recently used appended to the end.
    private var cache: [(key: String, content: PrewarmedContent)] = []
    /// FIFO of pending `(attachmentKey, fileURL)` requests. We pop one
    /// at a time; appended duplicates are coalesced before they enter
    /// the queue.
    private var pendingQueue: [(key: String, fileURL: URL)] = []
    /// Set of keys for entries currently queued or being processed.
    /// Used to coalesce repeat calls so a single attachment never
    /// occupies more than one slot end-to-end.
    private var queuedKeys: Set<String> = []
    private var isProcessing: Bool = false
    /// Reused off-screen host window - same pattern as
    /// `HTMLThumbnailRenderer`. Allocating a fresh window per prewarm
    /// leaks a `UIWindowScene.keyboardLayoutGuide` reservation, so the
    /// renderer reuses one. Mirroring that here.
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
        let size: CGSize = currentPrewarmSize(scene: scene)
        window.frame = CGRect(
            x: -100_000.0,
            y: -100_000.0,
            width: size.width,
            height: size.height
        )
        window.windowLevel = .normal - 1
        window.isUserInteractionEnabled = false
        window.isHidden = false
        return window
    }

    /// Resolve the prewarm size from the current scene's screen bounds.
    /// Matches the eventual sheet's content area on the user's device
    /// (iPhone / iPad, portrait / landscape, Stage Manager window)
    /// so the off-screen layout doesn't have to reflow on handoff.
    /// Falls back to a fixed iPhone canvas only when there's no scene
    /// to ask (early-launch edge case the offscreen window already
    /// guards against).
    private static func currentPrewarmSize(scene: UIWindowScene? = nil) -> CGSize {
        let resolvedScene: UIWindowScene? = scene ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState != .unattached }
        guard let resolvedScene else { return fallbackPrewarmSize }
        let bounds: CGRect = resolvedScene.screen.bounds
        guard bounds.width > 0, bounds.height > 0 else { return fallbackPrewarmSize }
        return bounds.size
    }

    /// Enqueues a background load for `(attachmentKey, fileURL)`. The
    /// queue processes one entry at a time; repeat calls for an already-
    /// cached or already-queued attachment are no-ops.
    public func prewarm(attachmentKey: String, fileURL: URL) {
        if cache.contains(where: { $0.key == attachmentKey }) {
            promote(attachmentKey: attachmentKey)
            return
        }
        if queuedKeys.contains(attachmentKey) { return }
        queuedKeys.insert(attachmentKey)
        pendingQueue.append((key: attachmentKey, fileURL: fileURL))
        processQueueIfIdle()
    }

    /// Removes and returns the cached `PrewarmedContent` if one exists.
    /// The caller takes full ownership of the WebView; nothing in the
    /// cache references it after this call.
    public func borrowContent(for attachmentKey: String) -> PrewarmedContent? {
        guard let index = cache.firstIndex(where: { $0.key == attachmentKey }) else { return nil }
        let entry = cache.remove(at: index)
        entry.content.webView.removeFromSuperview()
        return entry.content
    }

    private func promote(attachmentKey: String) {
        guard let index = cache.firstIndex(where: { $0.key == attachmentKey }) else { return }
        let entry = cache.remove(at: index)
        cache.append(entry)
    }

    private func processQueueIfIdle() {
        guard !isProcessing else { return }
        guard !pendingQueue.isEmpty else { return }
        let next = pendingQueue.removeFirst()
        isProcessing = true
        Task { @MainActor [weak self] in
            await self?.performPrewarm(attachmentKey: next.key, fileURL: next.fileURL)
            self?.queuedKeys.remove(next.key)
            self?.isProcessing = false
            self?.processQueueIfIdle()
        }
    }

    private func performPrewarm(attachmentKey: String, fileURL: URL) async {
        guard let window = offscreenWindow else {
            Log.error("HTMLContentPrewarmer: no offscreen window available; skipping prewarm of \(attachmentKey)")
            return
        }
        let coordinator = PrewarmCoordinator()
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: HTMLBodyBackgroundBridge.messageHandlerName)
        config.userContentController.addUserScript(HTMLBodyBackgroundBridge.makeUserScript())
        let size: CGSize = Self.currentPrewarmSize()
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: size),
            configuration: config
        )
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = coordinator
        window.addSubview(webView)
        let readAccessURL = fileURL.deletingLastPathComponent()
        webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        let success: Bool = await coordinator.waitForLoad(timeout: Self.loadTimeout, paintDelay: Self.paintDelay)
        guard success else {
            webView.stopLoading()
            webView.removeFromSuperview()
            return
        }
        let entry: PrewarmedContent = PrewarmedContent(
            webView: webView,
            bodyBackgroundColor: coordinator.bodyBackgroundColor
        )
        insert(attachmentKey: attachmentKey, content: entry)
    }

    private func insert(attachmentKey: String, content: PrewarmedContent) {
        cache.removeAll { $0.key == attachmentKey }
        cache.append((key: attachmentKey, content: content))
        while cache.count > Self.cacheLimit {
            let dropped = cache.removeFirst()
            dropped.content.webView.stopLoading()
            dropped.content.webView.removeFromSuperview()
        }
    }
}

private final class PrewarmCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private(set) var bodyBackgroundColor: Color?
    private var didFinishContinuation: CheckedContinuation<Bool, Never>?
    private var finished: Bool = false

    public func waitForLoad(timeout: TimeInterval, paintDelay: TimeInterval) async -> Bool {
        let success: Bool = await withCheckedContinuation { continuation in
            self.didFinishContinuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.complete(success: false)
            }
        }
        guard success else { return false }
        try? await Task.sleep(for: .seconds(paintDelay))
        return true
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        complete(success: true)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        Log.error("HTMLContentPrewarmer load failed: \(error.localizedDescription)")
        complete(success: false)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        Log.error("HTMLContentPrewarmer provisional load failed: \(error.localizedDescription)")
        complete(success: false)
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == HTMLBodyBackgroundBridge.messageHandlerName,
              let raw = message.body as? String else { return }
        bodyBackgroundColor = HTMLBodyBackgroundBridge.parseCSSColor(raw)
    }

    private func complete(success: Bool) {
        guard !finished else { return }
        finished = true
        didFinishContinuation?.resume(returning: success)
        didFinishContinuation = nil
    }
}
#endif
