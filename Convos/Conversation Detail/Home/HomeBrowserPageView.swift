import SwiftUI

/// One page in the home browsing chain. Each intercepted navigation
/// pushes a fresh entry; identity is per-tap so tapping the same link twice
/// still pushes.
struct HomeBrowserEntry: Identifiable, Hashable {
    let id: UUID = UUID()
    let url: URL
}

/// An external web page layered over the home, below the floating
/// conversation sheet - browsing never leaves the conversation screen, so
/// the sheet stays up and the top bar's back button (swapped in by
/// `ConversationView` while pages are open) walks the chain home to the
/// root home view. Mirrors the home surface's full-bleed geometry:
/// the page insets by the navigation chrome and the sheet so content
/// scrolls clear of both.
struct HomeBrowserPageView: View {
    let entry: HomeBrowserEntry
    /// The sheet's live geometry, whose coverage becomes this page's bottom
    /// content/indicator inset. Read here rather than handed in as a number - see
    /// `ConversationSheetGeometry`.
    var sheetGeometry: ConversationSheetGeometry = ConversationSheetGeometry()
    /// See `HomeLayoutView.bottomContentInsetOverride`.
    var bottomContentInsetOverride: CGFloat?
    /// Fired when this page requests navigation away from its own URL; the
    /// host pushes another page for it.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            HomeWebView(
                // An empty conversation id keeps browser pages from
                // overwriting the conversation's home cover snapshot.
                conversationId: "",
                url: entry.url,
                topContentInset: proxy.safeAreaInsets.top,
                bottomContentInset: bottomContentInsetOverride ?? sheetGeometry.homeBottomClearance,
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
