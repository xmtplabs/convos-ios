import SwiftUI

/// One page in the home browsing chain. Each intercepted navigation
/// pushes a fresh entry; identity is per-tap so tapping the same link twice
/// still pushes.
struct HomeBrowserEntry: Identifiable, Hashable {
    let id: UUID = UUID()
    let url: URL
    /// What the reader tapped to get here — a tile's caption. The page itself
    /// carries a heading, but the sheet's bar is drawn before the page has
    /// loaded, so the name has to come from the thing that was tapped.
    var title: String?
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
    /// Native destinations for this page's `window.convos` calls. Threaded
    /// through from the conversation so a sub-page (e.g. `/members`) can
    /// present the invite code, members list, etc. - without it these calls
    /// would hit the no-op default `HomeBridgeNavigation`.
    var bridgeNavigation: HomeBridgeNavigation = HomeBridgeNavigation()

    var body: some View {
        GeometryReader { proxy in
            // The page is presented, not pushed under the conversation's
            // chrome, so there is no segmented control to clear — only the
            // sheet's own safe area.
            let topInset: CGFloat = proxy.safeAreaInsets.top
            HomeWebView(
                url: entry.url,
                topContentInset: topInset,
                bottomContentInset: proxy.safeAreaInsets.bottom,
                onNavigationRequest: onNavigationRequest,
                bridgeNavigation: bridgeNavigation,
                // The pool is warmed for the Home's own URL. A browsed page has
                // nothing warm to inherit from it, and taking the idle view
                // would inherit the previous page's painted frame instead.
                usesPool: false
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
