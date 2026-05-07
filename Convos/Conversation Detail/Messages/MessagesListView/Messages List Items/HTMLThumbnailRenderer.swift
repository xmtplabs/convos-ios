import ConvosCore
import ConvosLogging
import UIKit
import WebKit

@MainActor
final class HTMLThumbnailRenderer {
    static let shared: HTMLThumbnailRenderer = HTMLThumbnailRenderer()

    private static let renderSize: CGSize = CGSize(width: 720, height: 1200)
    private static let paintDelay: TimeInterval = 0.5
    private static let cacheKeyPrefix: String = "html-thumb-v2-"
    private static let injectionScript: String = """
    (function() {
        var css = 'html, body { margin-top: 0 !important; padding-top: 0 !important; } ' +
                  '.note, .table, .note-hero, main, article { padding-top: 0 !important; margin-top: 0 !important; }';
        var style = document.createElement('style');
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
    })();
    """

    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private var cachedRenderWindow: UIWindow?

    private var renderWindow: UIWindow? {
        if let cachedRenderWindow, cachedRenderWindow.windowScene != nil {
            return cachedRenderWindow
        }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState != .background }
        guard let scene else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.renderSize)
        window.windowLevel = UIWindow.Level(rawValue: -1)
        window.alpha = 0.01
        window.rootViewController = UIViewController()
        window.isHidden = false
        cachedRenderWindow = window
        return window
    }

    static func cacheKey(for attachmentKey: String) -> String {
        cacheKeyPrefix + attachmentKey
    }

    func cachedThumbnail(for attachmentKey: String) -> UIImage? {
        ImageCache.shared.image(for: Self.cacheKey(for: attachmentKey))
    }

    func thumbnail(for attachmentKey: String, fileURL: URL) async -> UIImage? {
        let cacheKey = Self.cacheKey(for: attachmentKey)
        if let cached = await ImageCache.shared.imageAsync(for: cacheKey) {
            return cached
        }

        if let existing = inflight[attachmentKey] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            let image = await self.renderSnapshot(fileURL: fileURL)
            if let image {
                ImageCache.shared.cacheImage(image, for: cacheKey, storageTier: .cache)
            }
            return image
        }
        inflight[attachmentKey] = task
        let result = await task.value
        inflight.removeValue(forKey: attachmentKey)
        return result
    }

    private func renderSnapshot(fileURL: URL) async -> UIImage? {
        guard let window = renderWindow, let rootView = window.rootViewController?.view else {
            Log.error("HTMLThumbnailRenderer: no render window available")
            return nil
        }

        let config = WKWebViewConfiguration()
        let userScript = WKUserScript(
            source: Self.injectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)

        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: Self.renderSize),
            configuration: config
        )
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = true
        webView.isUserInteractionEnabled = false
        rootView.addSubview(webView)

        defer { webView.removeFromSuperview() }

        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let coordinator = LoadCoordinator { result in
                continuation.resume(returning: result)
            }
            // Retain coordinator for the duration of the load via objc association.
            objc_setAssociatedObject(webView, &Self.coordinatorAssocKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
            webView.navigationDelegate = coordinator

            let readAccessURL = fileURL.deletingLastPathComponent()
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        }
    }

    private nonisolated(unsafe) static var coordinatorAssocKey: UInt8 = 0
}

private final class LoadCoordinator: NSObject, WKNavigationDelegate {
    private let completion: (UIImage?) -> Void
    private var hasResumed: Bool = false

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak webView] in
            guard let self, !self.hasResumed, let webView else {
                self?.resume(image: nil)
                return
            }
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            webView.takeSnapshot(with: config) { image, error in
                if let error {
                    Log.error("HTMLThumbnailRenderer snapshot failed: \(error)")
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
}
