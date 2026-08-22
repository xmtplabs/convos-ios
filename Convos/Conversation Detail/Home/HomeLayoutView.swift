import SwiftUI

/// The Context tab's backing view: the conversation's Space web surface
/// filling the screen, with the preparing state covering the load. The page
/// owns its own vertical scrolling.
///
/// It used to be the surface the whole conversation sat on, with a floating
/// sheet over it whose resting height it reserved as bottom clearance. There is
/// no sheet now - this is one of three peer tabs, and the only thing floating
/// over it is the top chrome.
struct HomeLayoutView: View {
    var webURL: URL?
    /// Fired when the page requests navigation away from the space URL; the
    /// host presents it in the home browser popup.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    var body: some View {
        // The placeholder page (no URL) skips the insets - it fits the viewport
        // exactly and would otherwise gain a pointless scroll range.
        GeometryReader { proxy in
            let hasPage: Bool = webURL != nil
            // The safe area the surface is about to ignore, plus the segmented
            // control below the capsule. The page runs full-bleed under the
            // capsule by design, so only the switcher's own band is added -
            // clearing the whole chrome would push the page down twice.
            let topInset: CGFloat = proxy.safeAreaInsets.top + ConversationChromeMetrics.controlClearance
            HomeWebSurface(
                url: webURL,
                topContentInset: hasPage ? topInset : 0,
                bottomContentInset: hasPage ? proxy.safeAreaInsets.bottom : 0,
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
