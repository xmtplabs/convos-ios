import SwiftUI
import UIKit
import WebKit

/// The desktop web surface rendered behind the conversation sheet on the
/// Desktop tab. Loads the conversation's Space web URL when one has been
/// published into the group's appData; until then it shows an inline
/// placeholder page.
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
    /// Bottom clearance for the page and its scroll indicator - the floating
    /// conversation sheet's occupied height - so page content can scroll
    /// clear of the sheet while the surface itself stays full-bleed.
    var bottomContentInset: CGFloat = 0
    /// Fired on the main actor once the page finishes loading.
    var onLoaded: @MainActor () -> Void = {}
    /// Fired on the main actor when the page requests navigation away from
    /// the loaded space URL (link tap, JS redirect, target=_blank). The
    /// navigation is cancelled in place; the host presents it in the desktop
    /// browser popup instead.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(conversationId: conversationId, onLoaded: onLoaded, onNavigationRequest: onNavigationRequest)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        let raisedBackground = UIColor(named: "colorBackgroundRaised") ?? .systemBackground
        webView.backgroundColor = raisedBackground
        webView.scrollView.backgroundColor = raisedBackground
        webView.scrollView.isScrollEnabled = isScrollEnabled
        // The surface is positioned by SwiftUI (full-bleed under the floating
        // sheet); letting UIKit re-apply safe-area insets on top of that
        // makes a 100vh page scrollable and misplaces the indicator. The
        // sheet clearance arrives via `bottomContentInset` instead.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.conversationId = conversationId
        context.coordinator.onLoaded = onLoaded
        context.coordinator.onNavigationRequest = onNavigationRequest
        webView.scrollView.isScrollEnabled = isScrollEnabled
        if webView.scrollView.contentInset.bottom != bottomContentInset {
            webView.scrollView.contentInset.bottom = bottomContentInset
            webView.scrollView.verticalScrollIndicatorInsets.bottom = bottomContentInset
        }
        // Reload only when the destination actually changes; SwiftUI calls
        // this on unrelated state churn.
        guard context.coordinator.loadedURL != url || !context.coordinator.hasLoaded else { return }
        context.coordinator.loadedURL = url
        context.coordinator.hasLoaded = true
        // A fresh programmatic load may redirect; allow its whole chain again.
        context.coordinator.hasFinishedInitialLoad = false
        if let url {
            webView.load(URLRequest(url: url))
        } else {
            webView.loadHTMLString(Constant.placeholderHTML, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var conversationId: String
        var onLoaded: @MainActor () -> Void
        var onNavigationRequest: @MainActor (URL) -> Void
        var loadedURL: URL?
        var hasLoaded: Bool = false
        var hasFinishedInitialLoad: Bool = false

        init(
            conversationId: String,
            onLoaded: @escaping @MainActor () -> Void,
            onNavigationRequest: @escaping @MainActor (URL) -> Void
        ) {
            self.conversationId = conversationId
            self.onLoaded = onLoaded
            self.onNavigationRequest = onNavigationRequest
        }

        // WebKit calls navigation delegate methods on the main thread.
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

        // Links with target=_blank have no target frame; route them to the
        // popup instead of spawning a web view.
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            hasFinishedInitialLoad = true
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
            background: #ffffff;
            color: #8e8e93;
        }
        @media (prefers-color-scheme: dark) {
            body { background: #262626; }
        }
        </style>
        </head>
        <body><div>Desktop</div></body>
        </html>
        """
    }
}

/// Navigation interception shared by the desktop web surface and the browser
/// popups it spawns: each pins the page it initially loaded and hands any
/// user-driven navigation to the host, which stacks a new popup for it.
@MainActor
enum DesktopWebNavigation {
    /// The URL to intercept for `navigationAction`, or nil to let the
    /// navigation proceed in place. Allows subframe (iframe) loads, the
    /// initial load and its redirect chain, and same-URL reloads.
    static func interceptedURL(
        for navigationAction: WKNavigationAction,
        loadedURL: URL?,
        hasFinishedInitialLoad: Bool
    ) -> URL? {
        guard navigationAction.targetFrame?.isMainFrame == true else { return nil }
        guard let url = navigationAction.request.url else { return nil }
        if !hasFinishedInitialLoad || url == loadedURL { return nil }
        return url
    }

    /// Routes an intercepted URL: http(s) to the popup host, other schemes
    /// (mailto/tel) to the system.
    static func route(_ url: URL, toHost onNavigationRequest: @escaping @MainActor (URL) -> Void) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            Task { @MainActor in onNavigationRequest(url) }
        } else if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}
