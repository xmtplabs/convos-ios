import SwiftUI
import WebKit

/// The fullscreen desktop surface rendered behind the chat drawer in desktop
/// mode. Loads an inline placeholder page until a real desktop destination
/// exists; `url` is the seam where that swaps in.
struct DesktopWebView: UIViewRepresentable {
    /// Future real destination; nil loads the inline placeholder.
    var url: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reload only when the destination actually changes; SwiftUI calls
        // this on unrelated state churn.
        guard context.coordinator.loadedURL != url || !context.coordinator.hasLoaded else { return }
        context.coordinator.loadedURL = url
        context.coordinator.hasLoaded = true
        if let url {
            webView.load(URLRequest(url: url))
        } else {
            webView.loadHTMLString(Constant.placeholderHTML, baseURL: nil)
        }
    }

    final class Coordinator {
        var loadedURL: URL?
        var hasLoaded: Bool = false
    }

    private enum Constant {
        static let placeholderHTML: String = """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body {
            margin: 0;
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            font-family: -apple-system, sans-serif;
            background: #f2f2f7;
            color: #8e8e93;
        }
        @media (prefers-color-scheme: dark) {
            body { background: #1c1c1e; }
        }
        </style>
        </head>
        <body><div>Desktop</div></body>
        </html>
        """
    }
}
