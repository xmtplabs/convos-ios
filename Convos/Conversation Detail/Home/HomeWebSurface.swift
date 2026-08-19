import SwiftUI

/// Wraps `HomeWebView` with a cover that hides the loading page: the home's
/// preparing state, over the surface's own background. It sits on top until
/// the live page finishes loading, then cross-fades out to reveal it.
///
/// The cover is generated, never a captured image of the page: a picture of a
/// previous visit is not the page, and showing one claims the home still looks
/// like that while the real one is still loading.
struct HomeWebSurface: View {
    var url: URL?
    var isScrollEnabled: Bool = true
    /// Forwarded to `HomeWebView`: top clearance (the navigation chrome)
    /// for the page and its scroll indicator.
    var topContentInset: CGFloat = 0
    /// Forwarded to `HomeWebView`: bottom clearance (the floating sheet's
    /// occupied height) for the page and its scroll indicator.
    var bottomContentInset: CGFloat = 0
    /// Forwarded to `HomeWebView`; fired when the page requests navigation
    /// away from the space URL.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    @State private var isLoaded: Bool = false

    var body: some View {
        ZStack {
            HomeWebView(
                url: url,
                isScrollEnabled: isScrollEnabled,
                topContentInset: topContentInset,
                bottomContentInset: bottomContentInset,
                onLoaded: {
                    // Without a URL the web view loads its inline placeholder,
                    // which finishes immediately. That is not the space
                    // arriving, and revealing it would replace the preparing
                    // state with a bare "Home".
                    guard url != nil else { return }
                    // The reveal waits a beat past didFinish - a JS page
                    // hasn't painted yet at that moment - and only the
                    // fade animates: the cover must never fade IN, or the
                    // cleared layer shows through.
                    withAnimation(.easeInOut(duration: Constant.coverFadeDuration).delay(Constant.revealDelay)) {
                        isLoaded = true
                    }
                },
                onNavigationRequest: onNavigationRequest
            )
            HomeCoverView(hasSpaceURL: url != nil)
                .opacity(isLoaded ? 0 : 1)
                .allowsHitTesting(!isLoaded)
        }
        // A conversation that loses its space goes back to waiting for one, so
        // the cover comes back rather than leaving the last page on screen.
        .onChange(of: url) { _, newURL in
            if newURL == nil {
                isLoaded = false
            }
        }
    }

    private enum Constant {
        static let coverFadeDuration: Double = 0.35
        /// The gap between didFinish and the page's JS actually painting;
        /// revealing at didFinish would expose an unpainted canvas.
        static let revealDelay: Double = 0.6
    }
}

/// The cover drawn over the loading home: the preparing state on an opaque
/// canvas, which is what the surface shows until the page is ready.
private struct HomeCoverView: View {
    /// False until the worker publishes the space URL, which the preparing
    /// state uses to decide how far its bar may advance.
    let hasSpaceURL: Bool

    var body: some View {
        // Opaque fill (it must hide the loading page beneath), layered the same
        // way the home layout paints its background.
        ZStack {
            Color.colorBackgroundSurfaceless
            Color.colorBackgroundSubtle
            HomePreparingView(stage: hasSpaceURL ? .loadingPage : .awaitingSpace)
        }
    }
}
