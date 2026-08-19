import SwiftUI
import UIKit
import WebKit

/// The home web surface rendered behind the conversation sheet on the
/// Home tab. Loads the conversation's Space web URL when one has been
/// published into the group's appData; until then it shows an inline
/// placeholder page.
///
/// `onFirstPaint` fires when the page reports that it has actually drawn, and
/// `onLoaded` when the navigation finishes. The surface reveals on the first of
/// the two, so a page that paints early is not held behind a fixed wait and one
/// that paints late is not revealed blank.
struct HomeWebView: UIViewRepresentable {
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
    /// Fired on the main actor when the page reports its first contentful
    /// paint. See `HomeWebViewPaintReporter.script`.
    var onFirstPaint: @MainActor () -> Void = {}
    /// Fired on the main actor when the adopted view was already showing this
    /// page, drawn, before this view was built - so there is nothing to wait
    /// for and nothing to fade.
    var onAdoptedPainted: @MainActor () -> Void = {}
    /// Fired on the main actor when the page requests navigation away from
    /// the loaded space URL (link tap, JS redirect, target=_blank). The
    /// navigation is cancelled in place; the host presents it in the home
    /// browser popup instead.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLoaded: onLoaded,
            onFirstPaint: onFirstPaint,
            onNavigationRequest: onNavigationRequest
        )
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Back to the pool with what it is showing, so a page that is still
        // drawn can be handed straight back on re-entry.
        // The URL asked for, not the one that committed: a page that redirects
        // - or merely gains a trailing slash, as every bare host does - leaves
        // `loadedURL` on something the next request will never be phrased as,
        // so the kept page could never be matched to it.
        HomeWebViewPool.shared.release(
            webView,
            showing: coordinator.requestedURL,
            painted: coordinator.hasPainted
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        // Adopted rather than created: building one costs about a third of a
        // second before it can even start a navigation. See `HomeWebViewPool`.
        let adoption = HomeWebViewPool.shared.adoption(for: url)
        let webView = HomeWebViewPool.shared.acquire()
        let coordinator = context.coordinator
        HomeWebViewPool.shared.paintReporter(of: webView)?.onPaint = { source in
            MainActor.assumeIsolated { coordinator.reportPaint(source) }
        }
        // A page prepared while the screen was being pushed is already this
        // view's page: loading it again would throw away the head start and
        // show the cover for a second load of what is already drawn.
        coordinator.adoptPreparedLoad(adoption, url: url, onAdoptedPainted: onAdoptedPainted)
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
        context.coordinator.onLoaded = onLoaded
        context.coordinator.onFirstPaint = onFirstPaint
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
        context.coordinator.markLoadStarted()
        if let url {
            context.coordinator.activeNavigation = webView.load(URLRequest(url: url))
        } else {
            context.coordinator.activeNavigation = webView.loadHTMLString(Constant.placeholderHTML, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onLoaded: @MainActor () -> Void
        var onFirstPaint: @MainActor () -> Void
        var onNavigationRequest: @MainActor (URL) -> Void
        /// When the current load was started, for the stage timings. Nil once
        /// they have all been reported.
        private var loadStart: CFAbsoluteTime?
        /// Guards the paint timing so a page reporting more than once (or a
        /// stale load reporting late) logs a single figure.
        private var hasReportedPaint: Bool = false
        /// Whether the page this view is showing has drawn, for the pool to
        /// decide whether it is worth keeping.
        var hasPainted: Bool { hasReportedPaint }
        /// The URL the host last asked for, which is what decides whether an
        /// update pass is a new destination or SwiftUI churn. Distinct from
        /// `loadedURL`, which follows redirects.
        var requestedURL: URL?
        /// The URL currently committed in the web view - the initial request,
        /// or wherever its redirect chain landed. Navigation interception
        /// measures against this, so a reload of the displayed page is not
        /// mistaken for outbound navigation.
        var loadedURL: URL?
        var hasLoaded: Bool = false
        var hasFinishedInitialLoad: Bool = false
        /// The most recently started load; completions for anything else are
        /// stale (e.g. the placeholder finishing after the real Space URL
        /// superseded it) and must not flip the interception state.
        var activeNavigation: WKNavigation?

        init(
            onLoaded: @escaping @MainActor () -> Void,
            onFirstPaint: @escaping @MainActor () -> Void,
            onNavigationRequest: @escaping @MainActor (URL) -> Void
        ) {
            self.onLoaded = onLoaded
            self.onFirstPaint = onFirstPaint
            self.onNavigationRequest = onNavigationRequest
        }

        /// Starts the clock for a load the host just issued, so the stage
        /// timings measure from the request rather than from whenever WebKit
        /// got around to the navigation.
        func markLoadStarted() {
            loadStart = CFAbsoluteTimeGetCurrent()
            hasReportedPaint = false
            probeMainThreadLatency()
        }

        /// Measures how long an empty main-queue hop takes from the moment the
        /// load is issued.
        ///
        /// Every stage below is reported through a main-thread delegate
        /// callback, so a busy main thread inflates all of them equally and
        /// would read as WebKit being slow. This says which it is: near zero
        /// means the wait before the request is really WebKit's, and hundreds
        /// of milliseconds means the main thread was busy opening the
        /// conversation and the page never had a chance to start.
        private func probeMainThreadLatency() {
            let issued = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async {
                let waited = (CFAbsoluteTimeGetCurrent() - issued) * 1000.0
                Log.info("[PERF] HomeWebView.mainQueueLatency: \(String(format: "%.0f", waited))ms")
            }
        }

        /// Milliseconds since the load was issued, or nil if no load is being
        /// timed.
        private func elapsedMilliseconds() -> Double? {
            guard let loadStart else { return nil }
            return (CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0
        }

        private func logStage(_ stage: String) {
            guard let elapsed = elapsedMilliseconds() else { return }
            Log.info("[PERF] HomeWebView.\(stage): \(String(format: "%.0f", elapsed))ms")
        }

        /// Takes over a load the pool started before this view existed.
        ///
        /// Seeds the state `updateUIView` decides against, so it treats the
        /// destination as already requested and does not start it again. A page
        /// that has already painted has nothing left to wait for, so the
        /// surface is told at once rather than after a load it will never see.
        func adoptPreparedLoad(
            _ adoption: HomeWebViewPool.Adoption,
            url: URL?,
            onAdoptedPainted: @escaping @MainActor () -> Void
        ) {
            guard adoption != .unprepared, let url else { return }
            markLoadStarted()
            requestedURL = url
            loadedURL = url
            hasLoaded = true
            guard adoption == .painted else { return }
            hasReportedPaint = true
            hasFinishedInitialLoad = true
            Log.info("[PERF] HomeWebView.adoptedPainted: page was ready before the surface")
            Task { @MainActor in onAdoptedPainted() }
        }

        /// The page reporting that it has drawn. Reveals the surface without
        /// waiting out the fallback delay.
        func reportPaint(_ source: String) {
            guard !hasReportedPaint else { return }
            hasReportedPaint = true
            if let elapsed = elapsedMilliseconds() {
                Log.info("[PERF] HomeWebView.firstPaint(\(source)): \(String(format: "%.0f", elapsed))ms")
            }
            let onFirstPaint = onFirstPaint
            Task { @MainActor in onFirstPaint() }
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

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            guard isCurrent(navigation) else { return }
            // Splits the wait before the first byte in two: everything up to
            // here is WebKit getting a web content process ready to ask, and
            // everything from here to didCommit is DNS, TLS and the server.
            logStage("didStartProvisional")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
            guard isCurrent(navigation) else { return }
            // First bytes of the response: everything before this is DNS, TLS
            // and the server's own time.
            logStage("didCommit")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard isCurrent(navigation) else { return }
            logStage("didFinish")
            hasFinishedInitialLoad = true
            // The initial chain may have redirected; pin the final committed
            // URL so a later reload of the displayed page stays in place
            // instead of being intercepted as outbound navigation.
            loadedURL = webView.url ?? loadedURL
            let onLoaded = onLoaded
            Task { @MainActor in onLoaded() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            handleLoadFailure(navigation, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            handleLoadFailure(navigation, error: error)
        }

        /// A failed load must not strand the surface: clearing `hasLoaded` lets
        /// the next update pass retry the same URL. It also fires `onLoaded`,
        /// which drops the cover - so a failure currently reveals an empty web
        /// view rather than holding the preparing state until the retry lands.
        /// Cancellations (a newer load superseding this one) are not failures.
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
            Task { @MainActor in onNavigationRequest(url) }
        } else if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}
