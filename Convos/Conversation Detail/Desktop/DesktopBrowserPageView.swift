import SwiftUI

/// One pushed external page in the desktop browsing chain. Each intercepted
/// navigation pushes a fresh entry; identity is per-tap so tapping the same
/// link twice still pushes.
struct DesktopBrowserEntry: Identifiable, Hashable {
    let id: UUID = UUID()
    let url: URL
}

/// An external web page pushed onto the conversation's navigation stack from
/// the desktop. The system back button walks the chain back to the root
/// desktop view, and the conversation's own toolbar items (the add-members
/// button) stay behind on the conversation screen. Each pushed page pins the
/// URL it opened with and pushes the next page for any outbound navigation
/// (see `DesktopWebNavigation`).
struct DesktopBrowserPageView: View {
    let entry: DesktopBrowserEntry

    @State private var nextEntry: DesktopBrowserEntry?

    var body: some View {
        DesktopWebView(
            // An empty conversation id keeps pushed pages from overwriting
            // the conversation's desktop cover snapshot.
            conversationId: "",
            url: entry.url,
            onNavigationRequest: { url in
                nextEntry = DesktopBrowserEntry(url: url)
            }
        )
        .background {
            Color.colorBackgroundRaised
                .ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $nextEntry) { next in
            DesktopBrowserPageView(entry: next)
        }
    }
}
