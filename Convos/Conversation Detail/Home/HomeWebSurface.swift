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
    /// Forwarded to the preparing state, so its copy names the right thing.
    var subject: HomePreparingView.Subject = .group
    /// Forwarded to `HomeWebView`: top clearance (the navigation chrome)
    /// for the page and its scroll indicator.
    var topContentInset: CGFloat = 0
    /// Forwarded to `HomeWebView`: bottom clearance (the floating sheet's
    /// occupied height) for the page and its scroll indicator.
    var bottomContentInset: CGFloat = 0
    /// Forwarded to `HomeWebView`; fired when the page requests navigation
    /// away from the space URL.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    /// Whether the page is showing rather than the cover.
    ///
    /// Seeded from the pool, not from `false`: a page prepared while the reader
    /// was still on the list is already drawn when this view is built, and
    /// starting covered would put the preparing state over a finished home and
    /// then fade it out. The wait it describes has already happened.
    @State private var isLoaded: Bool

    init(
        url: URL? = nil,
        isScrollEnabled: Bool = true,
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        onNavigationRequest: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        self.url = url
        self.isScrollEnabled = isScrollEnabled
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.onNavigationRequest = onNavigationRequest
        _isLoaded = State(initialValue: HomeWebViewPool.shared.adoption(for: url) == .painted)
    }

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
                    // The fallback: a page that reports no paint at all still
                    // has to be revealed, and a beat past didFinish is the old
                    // guess at when it has drawn. `onFirstPaint` normally gets
                    // there first and makes this a no-op.
                    reveal(after: Constant.revealDelay)
                },
                onFirstPaint: {
                    guard url != nil else { return }
                    // The page says it has drawn, so there is nothing left to
                    // wait for.
                    reveal(after: 0)
                },
                onAdoptedPainted: {
                    // Already drawn before this view existed. Straight to the
                    // page, with no fade: there is no wait to describe, and
                    // animating one out is how a ready home still shows a
                    // progress bar.
                    isLoaded = true
                },
                onNavigationRequest: onNavigationRequest
            )
            HomeCoverView(hasSpaceURL: url != nil, subject: subject)
                .opacity(isLoaded ? 0 : 1)
                .allowsHitTesting(!isLoaded)
        }
        // Any change of url is a new page to wait for, so the cover comes back
        // rather than leaving the previous one on screen - live and touchable -
        // until the new one commits. That includes a space being republished at
        // a different address, not only one going away.
        .onChange(of: url) { _, _ in
            isLoaded = false
        }
    }

    /// Fades the cover away, optionally after a delay. Idempotent: the paint
    /// report and the finished navigation both ask for the reveal, and only the
    /// fade animates - the cover must never fade back IN, or the cleared layer
    /// shows through.
    private func reveal(after delay: Double) {
        guard !isLoaded else { return }
        withAnimation(.easeInOut(duration: Constant.coverFadeDuration).delay(delay)) {
            isLoaded = true
        }
    }

    private enum Constant {
        static let coverFadeDuration: Double = 0.35
        /// The fallback gap between didFinish and a page's JS painting, used
        /// only when the page reports no paint of its own.
        static let revealDelay: Double = 0.6
    }
}

/// The cover drawn over the loading home: the preparing state on an opaque
/// canvas, which is what the surface shows until the page is ready.
private struct HomeCoverView: View {
    /// False until the worker publishes the space URL, which the preparing
    /// state uses to decide how far its bar may advance.
    let hasSpaceURL: Bool
    let subject: HomePreparingView.Subject

    var body: some View {
        // Opaque fill (it must hide the loading page beneath), layered the same
        // way the home layout paints its background.
        ZStack {
            Color.colorBackgroundSurfaceless
            Color.colorBackgroundSubtle
            HomePreparingView(stage: hasSpaceURL ? .loadingPage : .awaitingSpace, subject: subject)
        }
    }
}
