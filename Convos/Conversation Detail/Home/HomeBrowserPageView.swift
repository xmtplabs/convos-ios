import SwiftUI

/// One page in the home browsing chain. Each intercepted navigation
/// pushes a fresh entry; identity is per-tap so tapping the same link twice
/// still pushes.
struct HomeBrowserEntry: Identifiable, Hashable {
    let id: UUID = UUID()
    let url: URL
}

/// An external web page layered over the Context tab's Space page - browsing
/// never leaves the conversation screen, so the top chrome stays put and its
/// back button (swapped in by `ConversationView` while pages are open) walks
/// the chain home to the root Space view.
///
/// Mirrors the Space surface's full-bleed geometry: the page insets by the top
/// chrome so content scrolls clear of it.
struct HomeBrowserPageView: View {
    let entry: HomeBrowserEntry
    /// Fired when this page requests navigation away from its own URL; the
    /// host pushes another page for it.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            let topInset: CGFloat = proxy.safeAreaInsets.top + ConversationChromeMetrics.controlClearance
            HomeWebView(
                // An empty conversation id keeps browser pages from
                // overwriting the conversation's home cover snapshot.
                conversationId: "",
                url: entry.url,
                topContentInset: topInset,
                bottomContentInset: proxy.safeAreaInsets.bottom,
                onNavigationRequest: onNavigationRequest
            )
            .ignoresSafeArea(edges: .vertical)
        }
        .background {
            Color.colorBackgroundRaised
                .ignoresSafeArea()
        }
        .accessibilityIdentifier("home-browser-page")
    }
}
