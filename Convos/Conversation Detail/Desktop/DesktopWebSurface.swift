import SwiftUI

/// Wraps `DesktopWebView` with a cover that hides the reloading page. The cover
/// is the last persisted snapshot of this conversation's desktop, or a neutral
/// placeholder the first time it opens (or after the OS purges the cache). It
/// sits on top until the live page finishes loading, then cross-fades out to
/// reveal it.
struct DesktopWebSurface: View {
    let conversationId: String
    var url: URL?
    var isScrollEnabled: Bool = true
    /// Forwarded to `DesktopWebView`: top clearance (the navigation chrome)
    /// for the page and its scroll indicator.
    var topContentInset: CGFloat = 0
    /// Forwarded to `DesktopWebView`: bottom clearance (the floating sheet's
    /// occupied height) for the page and its scroll indicator.
    var bottomContentInset: CGFloat = 0
    /// Forwarded to `DesktopWebView`: asks the loaded page for an in-place
    /// reload when bumped.
    var reloadNonce: Int = 0
    /// Forwarded to `DesktopWebView`; fired when the page requests navigation
    /// away from the space URL.
    var onNavigationRequest: @MainActor (URL) -> Void = { _ in }

    @State private var isLoaded: Bool = false
    @State private var coverImage: UIImage?

    var body: some View {
        ZStack {
            DesktopWebView(
                conversationId: conversationId,
                url: url,
                isScrollEnabled: isScrollEnabled,
                topContentInset: topContentInset,
                bottomContentInset: bottomContentInset,
                reloadNonce: reloadNonce,
                onLoaded: {
                    // Only the reveal animates; the cover itself is raised
                    // instantly (see the reload hook below), or the cleared
                    // web view would show through its fade-in.
                    withAnimation(.easeInOut(duration: Constant.coverFadeDuration)) {
                        isLoaded = true
                    }
                },
                onNavigationRequest: onNavigationRequest
            )
            DesktopCoverView(image: coverImage)
                .opacity(isLoaded ? 0 : 1)
                .allowsHitTesting(!isLoaded)
        }
        .task(id: conversationId) {
            let data: Data? = await DesktopSnapshotStore.shared.snapshotData(for: conversationId)
            coverImage = data.flatMap { UIImage(data: $0) }
        }
        // An in-place reload clears the transparent web view's content
        // layer mid-flight, which reads as the page blinking out. The last
        // stored snapshot is a capture of exactly what's on screen, so
        // raising the cover (instantly - identical pixels) holds the frame
        // through the reload, then cross-fades to the fresh page on finish.
        .onChange(of: reloadNonce) { _, _ in
            guard url != nil else { return }
            Task {
                let data: Data? = await DesktopSnapshotStore.shared.snapshotData(for: conversationId)
                guard let data, let image = UIImage(data: data) else { return }
                coverImage = image
                isLoaded = false
            }
        }
    }

    private enum Constant {
        static let coverFadeDuration: Double = 0.35
    }
}

/// The cover drawn over the reloading desktop: the persisted snapshot when one
/// exists, otherwise a neutral placeholder matching the web view's own empty
/// state.
private struct DesktopCoverView: View {
    let image: UIImage?

    var body: some View {
        if let image {
            // Contain the fill: `scaledToFill` reports the image's oversized
            // ideal frame, and an uncontained overflow here inflates the
            // conversation's whole backing ZStack past the screen. Drawing it
            // as an overlay on a container-sized base keeps the cover exactly
            // the surface's size.
            Color.clear
                .overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
        } else {
            // Opaque canvas fill (it must hide the loading page beneath),
            // layered the same way the desktop layout paints its background.
            ZStack {
                Color.colorBackgroundSurfaceless
                Color.colorBackgroundSubtle
                Text("Desktop")
                    .font(.largeTitle)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
    }
}
