import ConvosCore
import ConvosLogging
import PDFKit
import UIKit
import WebKit

@MainActor
final class HTMLThumbnailRenderer {
    static let shared: HTMLThumbnailRenderer = HTMLThumbnailRenderer()

    private static let renderSize: CGSize = CGSize(width: 720, height: 1200)
    fileprivate static let paintDelay: TimeInterval = 0.5
    private static let loadTimeout: TimeInterval = 15.0
    private static let cacheKeyPrefix: String = "html-thumb-v3-"
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

    /// Renders the file at `fileURL` to a `UIImage` without ever attaching a
    /// `WKWebView` to a `UIWindow`. The WebView lives only as an in-memory
    /// object: it loads the HTML, hands a vector PDF to PDFKit on
    /// `didFinish`, and is deallocated. There is no scene attachment and no
    /// `UIWindowScene.keyboardLayoutGuide` reservation to leak.
    private func renderSnapshot(fileURL: URL, appearance: UIUserInterfaceStyle) async -> UIImage? {
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
        // Drives `@media (prefers-color-scheme: ...)` resolution inside the
        // loaded HTML — the WebView's traitCollection determines what
        // matchMedia returns regardless of view-hierarchy attachment.
        webView.overrideUserInterfaceStyle = appearance

        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let coordinator = LoadCoordinator(renderSize: Self.renderSize) { result in
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
            let pdfConfig = WKPDFConfiguration()
            pdfConfig.rect = CGRect(origin: .zero, size: renderSize)
            webView.createPDF(configuration: pdfConfig) { result in
                switch result {
                case .success(let data):
                    let image = Self.rasterize(pdfData: data, at: renderSize)
                    self.resume(image: image)
                case .failure(let error):
                    Log.error("HTMLThumbnailRenderer createPDF failed: \(error)")
                    self.resume(image: nil)
                }
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

    private static func rasterize(pdfData: Data, at size: CGSize) -> UIImage? {
        guard let document = PDFDocument(data: pdfData), let page = document.page(at: 0) else {
            Log.error("HTMLThumbnailRenderer PDF had no first page")
            return nil
        }
        // page.thumbnail draws onto an opaque white background, which matches
        // the prior takeSnapshot behavior for HTML that doesn't set its own
        // body background.
        let image = page.thumbnail(of: size, for: .mediaBox)
        return image
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
