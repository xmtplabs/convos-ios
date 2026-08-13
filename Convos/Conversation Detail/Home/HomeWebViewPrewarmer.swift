import ConvosCore
import UIKit
import WebKit

/// Warms a WKWebView (and its out-of-process WebContent backing) at launch so
/// the first real home surface renders without paying the cold WebKit
/// spin-up cost. Loads a blank page into an offscreen, non-interactive web
/// view parked behind the app UI; it never becomes visible.
///
/// Only runs after the session reaches inbox-ready, so the warm-up stays off
/// the contention-heavy launch path (mirrors
/// `ConvosApp.startMetricsIdentification`). Everything that can run off the
/// main thread does; only the UIKit/WebKit touches hop to the main actor.
enum HomeWebViewPrewarmer {
    /// Retains the offscreen web view for the lifetime of the process so its
    /// backing WebContent process stays warm.
    @MainActor private static var warmWebView: WKWebView?

    static func prewarmIfNeeded(session: any SessionManagerProtocol) {
        Task.detached(priority: .utility) {
            do {
                _ = try await session.messagingService().sessionStateManager.waitForInboxReadyResult()
            } catch {
                // Warm-up is best-effort; a failed session bind just skips it.
                return
            }
            await MainActor.run { warm() }
        }
    }

    @MainActor
    private static func warm() {
        guard warmWebView == nil else { return }
        guard let url = URL(string: "about:none") else { return }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.isUserInteractionEnabled = false
        webView.isHidden = true
        warmWebView = webView
        attachBehindAppUI(webView)
        webView.load(URLRequest(url: url))
    }

    /// Parks the web view at the back of the key window so it is attached to a
    /// window (which WebKit needs to actually drive the load) without ever
    /// appearing over or intercepting the app UI.
    @MainActor
    private static func attachBehindAppUI(_ webView: WKWebView) {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard let keyWindow else { return }
        webView.frame = .zero
        keyWindow.insertSubview(webView, at: 0)
    }
}
