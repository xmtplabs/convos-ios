import SwiftUI

/// The Desktop tab's backing view: the conversation's Space web surface
/// filling the screen behind the floating conversation sheet, with the
/// snapshot cover hiding reloads. The page owns its own vertical scrolling.
struct DesktopLayoutView: View {
    /// Keys the web section's persisted cover snapshot.
    var conversationId: String = ""
    var webURL: URL?
    /// Fired when the page requests navigation away from the space URL; the
    /// host presents it in the desktop browser popup.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    var body: some View {
        DesktopWebSurface(
            conversationId: conversationId,
            url: webURL,
            onNavigationRequest: onNavigationRequest
        )
        .ignoresSafeArea(edges: .bottom)
        .background {
            Color.colorBackgroundSubtle
                .ignoresSafeArea()
        }
        .accessibilityIdentifier("desktop-web-section")
    }
}

#Preview {
    DesktopLayoutView()
}
