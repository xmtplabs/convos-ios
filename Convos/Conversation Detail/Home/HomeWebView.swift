import SwiftUI
import UIKit
import WebKit

/// The home web surface rendered behind the conversation sheet on the
/// Home tab. Loads the conversation's Space web URL when one has been
/// published into the group's appData; until then it shows an inline
/// placeholder page.
///
/// On every finished load it captures a snapshot of the rendered page and
/// hands it to `HomeSnapshotStore`, keyed by `conversationId`, so the next
/// time this conversation's home opens it can show that image as a cover
/// while the live page reloads. `onLoaded` fires at the same moment so the
/// cover can cross-fade out.
struct HomeWebView: UIViewRepresentable {
    /// Identifies which conversation's snapshot this load should persist under.
    var conversationId: String
    /// The conversation's Space web URL; nil loads the inline placeholder.
    var url: URL?
    /// False when an outer scroll view (the home layout) owns the
    /// vertical gesture.
    var isScrollEnabled: Bool = true
    /// Top clearance for the page and its scroll indicator - the navigation
    /// chrome's height - so page content can scroll fully below the floating
    /// top bar while the surface itself stays full-bleed.
    var topContentInset: CGFloat = 0
    /// Bottom clearance for the page and its scroll indicator - the floating
    /// conversation sheet's occupied height - so page content can scroll
    /// clear of the sheet while the surface itself stays full-bleed.
    var bottomContentInset: CGFloat = 0
    /// Fired on the main actor once the page finishes loading.
    var onLoaded: @MainActor () -> Void = {}
    /// Fired on the main actor when the page requests navigation away from
    /// the loaded space URL (link tap, JS redirect, target=_blank). The
    /// navigation is cancelled in place; the host presents it in the home
    /// browser popup instead.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            conversationId: conversationId,
            onLoaded: onLoaded,
            onNavigationRequest: onNavigationRequest
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Transparent web chrome: the SwiftUI host paints the home canvas
        // (the conversation background), and the placeholder page leaves its
        // body transparent so both stay one surface until a Space page with
        // its own background loads.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = isScrollEnabled
        // The surface is positioned by SwiftUI (full-bleed under the floating
        // sheet); letting UIKit re-apply safe-area insets on top of that
        // makes a 100vh page scrollable and misplaces the indicator. The
        // chrome clearances arrive via the explicit content insets instead -
        // and the indicator's automatic adjustment is its own flag, applied
        // even with `.never`, so it must be silenced too or the safe areas
        // stack onto the manual indicator insets.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.conversationId = conversationId
        context.coordinator.onLoaded = onLoaded
        context.coordinator.onNavigationRequest = onNavigationRequest
        webView.scrollView.isScrollEnabled = isScrollEnabled
        let scrollView = webView.scrollView
        if scrollView.contentInset.top != topContentInset || scrollView.contentInset.bottom != bottomContentInset {
            // A page resting at the top must stay at the (new) top: with
            // manual insets the resting offset is -inset.top, and UIKit
            // doesn't shift it when the inset changes.
            let wasAtTop: Bool = scrollView.contentOffset.y <= -scrollView.contentInset.top + 1
            scrollView.contentInset.top = topContentInset
            scrollView.contentInset.bottom = bottomContentInset
            scrollView.verticalScrollIndicatorInsets.top = topContentInset
            scrollView.verticalScrollIndicatorInsets.bottom = bottomContentInset
            if wasAtTop {
                scrollView.contentOffset.y = -topContentInset
            }
        }
        // Reload only when the destination actually changes; SwiftUI calls
        // this on unrelated state churn. Compared against the URL we were
        // asked for rather than the one that committed: a page that redirects
        // leaves `loadedURL` on its destination, which would never match the
        // prop again and would reload on every later update pass.
        guard context.coordinator.requestedURL != url || !context.coordinator.hasLoaded else { return }
        context.coordinator.requestedURL = url
        context.coordinator.loadedURL = url
        context.coordinator.hasLoaded = true
        // A fresh programmatic load may redirect; allow its whole chain again.
        // Tracking the returned navigation lets the coordinator ignore stale
        // completions from a superseded load.
        context.coordinator.hasFinishedInitialLoad = false
        if let url {
            context.coordinator.isShowingPlaceholder = false
            context.coordinator.activeNavigation = webView.load(URLRequest(url: url))
        } else {
            context.coordinator.isShowingPlaceholder = true
            context.coordinator.activeNavigation = webView.loadHTMLString(Constant.placeholderHTML, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var conversationId: String
        var onLoaded: @MainActor () -> Void
        var onNavigationRequest: @MainActor (URL) -> Void
        /// The URL the host last asked for, which is what decides whether an
        /// update pass is a new destination or SwiftUI churn. Distinct from
        /// `loadedURL`, which follows redirects.
        var requestedURL: URL?
        /// The URL currently committed in the web view - the initial request,
        /// or wherever its redirect chain landed. Navigation interception
        /// measures against this, so a reload of the displayed page is not
        /// mistaken for outbound navigation.
        var loadedURL: URL?
        /// True while the inline placeholder is what is loaded. It is not this
        /// conversation's home, so it must never be persisted as the cover
        /// snapshot: doing so caches an image reading "Home" that then shows on
        /// every later open in place of the preparing state.
        var isShowingPlaceholder: Bool = false
        var hasLoaded: Bool = false
        var hasFinishedInitialLoad: Bool = false
        /// The most recently started load; completions for anything else are
        /// stale (e.g. the placeholder finishing after the real Space URL
        /// superseded it) and must not flip the interception state.
        var activeNavigation: WKNavigation?

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
            guard let url = HomeWebNavigation.interceptedURL(
                for: navigationAction,
                loadedURL: loadedURL,
                hasFinishedInitialLoad: hasFinishedInitialLoad
            ) else {
                return .allow
            }
            HomeWebNavigation.route(url, toHost: onNavigationRequest)
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
                HomeWebNavigation.route(url, toHost: onNavigationRequest)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard isCurrent(navigation) else { return }
            hasFinishedInitialLoad = true
            // The initial chain may have redirected; pin the final committed
            // URL so a later reload of the displayed page stays in place
            // instead of being intercepted as outbound navigation.
            loadedURL = webView.url ?? loadedURL
            let onLoaded = onLoaded
            Task { @MainActor in onLoaded() }
            // Pushed browser pages pass no conversation id; only the
            // conversation's own home persists a cover snapshot.
            let conversationId = conversationId
            guard !conversationId.isEmpty, !isShowingPlaceholder else { return }
            // The Space page is a JS app: at didFinish it hasn't painted
            // yet, and an immediate capture stores a blank cover. Give it a
            // beat to render before persisting.
            let navigation = navigation
            DispatchQueue.main.asyncAfter(deadline: .now() + Constant.snapshotDelay) { [weak self, weak webView] in
                guard let self, let webView, self.isCurrent(navigation) else { return }
                webView.takeSnapshot(with: nil) { image, error in
                    if let error {
                        Log.error("HomeWebView snapshot failed: \(error)")
                    }
                    guard let pngData = image?.pngData() else { return }
                    Task { await HomeSnapshotStore.shared.store(pngData, for: conversationId) }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            handleLoadFailure(navigation, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            handleLoadFailure(navigation, error: error)
        }

        /// A failed load must not strand the surface: clearing `hasLoaded`
        /// lets the next update pass retry the same URL, and firing
        /// `onLoaded` drops the snapshot cover so the surface isn't an
        /// opaque, untouchable ghost while it waits. Cancellations (a newer
        /// load superseding this one) are not failures.
        private func handleLoadFailure(_ navigation: WKNavigation?, error: Error) {
            guard isCurrent(navigation) else { return }
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            Log.warning("HomeWebView load failed: \(error.localizedDescription)")
            hasLoaded = false
            let onLoaded = onLoaded
            Task { @MainActor in onLoaded() }
        }

        /// Whether a delegate callback belongs to the most recently started
        /// load. WebKit occasionally reports a nil navigation; accept those
        /// rather than dropping real completions.
        private func isCurrent(_ navigation: WKNavigation?) -> Bool {
            navigation == nil || activeNavigation == nil || navigation === activeNavigation
        }
    }

    private enum Constant {
        /// How long after didFinish the persisted cover snapshot waits for
        /// the page's JS to actually paint.
        static let snapshotDelay: TimeInterval = 1.0
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
            background: transparent;
            color: #8e8e93;
        }
        </style>
        </head>
        <body><div>Home</div></body>
        </html>
        """
    }
}

/// Navigation interception shared by the home web surface and the browser
/// popups it spawns: each pins the page it initially loaded and hands any
/// user-driven navigation to the host, which stacks a new popup for it.
@MainActor
enum HomeWebNavigation {
    /// The URL to intercept for `navigationAction`, or nil to let the
    /// navigation proceed in place. Allows subframe (iframe) loads, the
    /// initial load and its redirect chain, same-URL reloads, and
    /// same-document fragment jumps (an anchor link scrolls the page; it
    /// isn't outbound navigation).
    static func interceptedURL(
        for navigationAction: WKNavigationAction,
        loadedURL: URL?,
        hasFinishedInitialLoad: Bool
    ) -> URL? {
        guard navigationAction.targetFrame?.isMainFrame == true else { return nil }
        guard let url = navigationAction.request.url else { return nil }
        if !hasFinishedInitialLoad || url == loadedURL { return nil }
        if isSameDocument(url, as: loadedURL) { return nil }
        return url
    }

    /// Whether two URLs differ only by fragment (`page` vs `page#section`).
    private static func isSameDocument(_ url: URL, as loadedURL: URL?) -> Bool {
        guard let loadedURL else { return false }
        return strippingFragment(url) == strippingFragment(loadedURL)
    }

    private static func strippingFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    /// Routes an intercepted URL: http(s) to the popup host, other schemes
    /// (mailto/tel) to the system.
    static func route(_ url: URL, toHost onNavigationRequest: @escaping @MainActor (URL) -> Void) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            // Google Docs links leave the app entirely: `open` honors the
            // universal link, landing in the Docs app when installed and
            // Safari otherwise, which beats the popup's mobile web view.
            if url.host?.lowercased() == "docs.google.com" {
                Task { @MainActor in UIApplication.shared.open(url) }
            } else {
                Task { @MainActor in onNavigationRequest(url) }
            }
        } else if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}
