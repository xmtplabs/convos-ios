import UIKit
import WebKit

@MainActor
final class ArtifactPreviewSnapshotter: NSObject {
    enum Mode: String {
        case light
        case dark

        var userInterfaceStyle: UIUserInterfaceStyle {
            switch self {
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum SnapshotError: Error {
        case snapshotFailed
        case loadFailed
    }

    static let renderSize: CGFloat = 1400.0

    private static var liveSnapshotters: Set<ArtifactPreviewSnapshotter> = []

    private var continuation: CheckedContinuation<UIImage, Error>?
    private var webView: WKWebView?

    static func snapshot(html: String, mode: Mode) async throws -> UIImage {
        let snapshotter = ArtifactPreviewSnapshotter()
        liveSnapshotters.insert(snapshotter)
        defer { liveSnapshotters.remove(snapshotter) }
        return try await snapshotter.run(html: html, mode: mode)
    }

    private func run(html: String, mode: Mode) async throws -> UIImage {
        let frame = CGRect(x: 0, y: 0, width: Self.renderSize, height: Self.renderSize)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        webView.isOpaque = true
        webView.scrollView.isScrollEnabled = false
        webView.overrideUserInterfaceStyle = mode.userInterfaceStyle
        webView.navigationDelegate = self
        attachOffscreen(webView)
        self.webView = webView

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UIImage, Error>) in
            self.continuation = cont
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func attachOffscreen(_ view: UIView) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else {
            return
        }
        view.frame = view.frame.offsetBy(dx: -Self.renderSize - 100.0, dy: -Self.renderSize - 100.0)
        view.alpha = 0
        window.addSubview(view)
    }

    private func performSnapshot() {
        guard let webView else { return }
        let snapConfig = WKSnapshotConfiguration()
        snapConfig.rect = CGRect(x: 0, y: 0, width: Self.renderSize, height: Self.renderSize)
        snapConfig.afterScreenUpdates = true

        webView.takeSnapshot(with: snapConfig) { [weak self] image, error in
            Task { @MainActor in
                guard let self else { return }
                self.webView?.removeFromSuperview()
                self.webView = nil
                if let image {
                    self.continuation?.resume(returning: image)
                } else {
                    self.continuation?.resume(throwing: error ?? SnapshotError.snapshotFailed)
                }
                self.continuation = nil
            }
        }
    }
}

extension ArtifactPreviewSnapshotter: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            performSnapshot()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        webView.removeFromSuperview()
        self.webView = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        webView.removeFromSuperview()
        self.webView = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
