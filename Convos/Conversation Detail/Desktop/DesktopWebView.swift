import SwiftUI
import WebKit

/// The fullscreen desktop surface rendered behind the chat drawer in desktop
/// mode. Loads the conversation's Space web URL when one has been published
/// into the group's appData; until then it shows an inline placeholder page.
///
/// On every finished load it captures a snapshot of the rendered page and
/// hands it to `DesktopSnapshotStore`, keyed by `conversationId`, so the next
/// time this conversation's desktop opens it can show that image as a cover
/// while the live page reloads. `onLoaded` fires at the same moment so the
/// cover can cross-fade out.
struct DesktopWebView: UIViewRepresentable {
    /// Identifies which conversation's snapshot this load should persist under.
    var conversationId: String
    /// The conversation's Space web URL; nil loads the inline placeholder.
    var url: URL?
    /// False when an outer scroll view (the desktop layout) owns the
    /// vertical gesture.
    var isScrollEnabled: Bool = true
    /// Fired on the main actor once the page finishes loading.
    var onLoaded: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(conversationId: conversationId, onLoaded: onLoaded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.isScrollEnabled = isScrollEnabled
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.conversationId = conversationId
        context.coordinator.onLoaded = onLoaded
        webView.scrollView.isScrollEnabled = isScrollEnabled
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        var conversationId: String
        var onLoaded: @MainActor () -> Void
        var loadedURL: URL?
        var hasLoaded: Bool = false

        init(conversationId: String, onLoaded: @escaping @MainActor () -> Void) {
            self.conversationId = conversationId
            self.onLoaded = onLoaded
        }

        // WebKit calls navigation delegate methods on the main thread.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            let onLoaded = onLoaded
            Task { @MainActor in onLoaded() }
            let conversationId = conversationId
            webView.takeSnapshot(with: nil) { image, error in
                if let error {
                    Log.error("DesktopWebView snapshot failed: \(error)")
                }
                guard let pngData = image?.pngData() else { return }
                Task { await DesktopSnapshotStore.shared.store(pngData, for: conversationId) }
            }
        }
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
