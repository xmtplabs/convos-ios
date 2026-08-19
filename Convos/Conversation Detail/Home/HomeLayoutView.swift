import SwiftUI

/// The Home tab's backing view: the conversation's Space web surface
/// filling the screen behind the floating conversation sheet, with the
/// preparing state covering the load. The page owns its own vertical scrolling.
struct HomeLayoutView: View {
    var webURL: URL?
    /// Whose home this is - see `HomePreparingView.Subject`.
    var subject: HomePreparingView.Subject = .group
    /// The sheet's live geometry, read here rather than handed in as a number:
    /// the read is what makes a view update when the sheet moves, and this is
    /// the view that should update. See `ConversationSheetGeometry`.
    ///
    /// The web frame runs full-bleed under the floating sheet so page content
    /// stays visible around it while scrolling; the sheet's coverage is applied
    /// as the page's bottom content/indicator inset so everything can still
    /// scroll clear of the card. The placeholder page (no URL) skips the inset -
    /// it fits the viewport exactly and would otherwise gain a pointless scroll
    /// range.
    var sheetGeometry: ConversationSheetGeometry = ConversationSheetGeometry()
    /// Fired when the page requests navigation away from the space URL; the
    /// host presents it in the home browser popup.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    var body: some View {
        // The proxy reads the top safe area (status bar + navigation chrome)
        // that the surface is about to ignore, so the page insets by it and
        // can scroll fully below the floating top bar.
        GeometryReader { proxy in
            HomeWebSurface(
                url: webURL,
                subject: subject,
                topContentInset: webURL != nil ? proxy.safeAreaInsets.top : 0,
                bottomContentInset: webURL != nil ? sheetGeometry.homeBottomClearance : 0,
                onNavigationRequest: onNavigationRequest
            )
            .ignoresSafeArea(edges: .vertical)
        }
        // The conversation ambient: the subtle wash over the surfaceless
        // base (subtle alone is a low-alpha black and needs the base under
        // it). Shows through the transparent web view until a Space page
        // paints its own background.
        .background {
            ZStack {
                Color.colorBackgroundSurfaceless
                Color.colorBackgroundSubtle
            }
            .ignoresSafeArea()
        }
        .accessibilityIdentifier("home-web-section")
    }
}

#Preview {
    HomeLayoutView()
}
