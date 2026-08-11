import ConvosComposer
import SwiftUI
import UIKit
import WebKit

/// The glass browser popup presented when the desktop web surface intercepts
/// a navigation request. In the conversation screen's desktop ZStack it sits
/// above `DesktopLayoutView` and below `ConversationDrawer`, so the drawer
/// stays usable on top. The web view fills the screen edge to edge inside a
/// glass panel that morphs in and out; a glass circle close button floats
/// top-trailing inside the safe area.
struct DesktopBrowserOverlay: View {
    let url: URL
    /// Called after the dismiss morph completes; the host clears its URL state.
    var onClose: () -> Void

    @State private var isRevealed: Bool = false
    @Namespace private var namespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GlassEffectContainer {
                if isRevealed {
                    browserPanel
                }
            }
            if isRevealed {
                closeButton
                    .padding(.top, DesignConstants.Spacing.step3x)
                    .padding(.trailing, DesignConstants.Spacing.step4x)
                    .transition(.blurReplace)
            }
        }
        .onAppear(perform: reveal)
    }

    private var browserPanel: some View {
        DesktopBrowserWebView(url: url)
            .clipShape(.rect(cornerRadius: Constant.cornerRadius))
            .glassEffect(.regular, in: .rect(cornerRadius: Constant.cornerRadius))
            .glassEffectID("desktopBrowserPanel", in: namespace)
            .glassEffectTransition(.matchedGeometry)
            .ignoresSafeArea()
    }

    // The close button lives outside the glass container so its glass stays a
    // distinct circle instead of merging with the panel behind it.
    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.body.weight(.medium))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: Constant.closeButtonSize, height: Constant.closeButtonSize)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("desktop-browser-close")
    }

    private func reveal() {
        withAnimation(.bouncy(duration: Constant.revealDuration)) {
            isRevealed = true
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isRevealed = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Constant.dismissDelay) {
            onClose()
        }
    }

    private enum Constant {
        static let cornerRadius: CGFloat = DesignConstants.CornerRadius.large
        static let closeButtonSize: CGFloat = 44.0
        static let revealDuration: Double = 0.4
        static let dismissDelay: Double = 0.4
    }
}

/// A plain browsing web view for the popup: navigation inside it is normal
/// (no interception, no snapshotting). Links targeting a new window load in
/// place instead.
private struct DesktopBrowserWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        let raisedBackground = UIColor(named: "colorBackgroundRaised") ?? .systemBackground
        webView.backgroundColor = raisedBackground
        webView.scrollView.backgroundColor = raisedBackground
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Load only when the destination changes; SwiftUI calls this on
        // unrelated state churn.
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKUIDelegate {
        var loadedURL: URL?

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            webView.load(navigationAction.request)
            return nil
        }
    }
}

#Preview {
    ZStack {
        Color.colorBackgroundSubtle
            .ignoresSafeArea()
        if let url = URL(string: "https://convos.org") {
            DesktopBrowserOverlay(url: url, onClose: {})
        }
    }
}
