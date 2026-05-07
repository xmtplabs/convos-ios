import SwiftUI
import UIKit
import WebKit

struct HTMLAttachmentPreviewSheet: View {
    let fileURL: URL
    let filename: String
    let attachmentKey: String
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var resolvedTitle: String?
    @State private var bodyBackgroundColor: UIColor?

    private var displayTitle: String {
        if let resolvedTitle, !resolvedTitle.isEmpty { return resolvedTitle }
        return filename
    }

    private var preferredScheme: ColorScheme? {
        guard let color = bodyBackgroundColor else { return nil }
        return color.convos_isDark ? .dark : .light
    }

    var body: some View {
        NavigationStack {
            HTMLAttachmentWebView(
                fileURL: fileURL,
                onBodyBackgroundColor: { color in
                    bodyBackgroundColor = color
                }
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: attachmentKey) {
                if let cached = HTMLPageMetadata.shared.cachedTitle(for: attachmentKey) {
                    resolvedTitle = cached
                    return
                }
                resolvedTitle = await HTMLPageMetadata.shared.title(for: attachmentKey, fileURL: fileURL)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    let action = { dismiss() }
                    Button("Done", action: action)
                }
            }
        }
        .preferredColorScheme(preferredScheme)
    }
}

private struct HTMLAttachmentWebView: UIViewRepresentable {
    let fileURL: URL
    let onBodyBackgroundColor: (UIColor?) -> Void

    private static let bgScript: String = """
    (function() {
        function postBg() {
            var bg = getComputedStyle(document.body).backgroundColor;
            if (!bg || bg === 'rgba(0, 0, 0, 0)' || bg === 'transparent') {
                bg = getComputedStyle(document.documentElement).backgroundColor;
            }
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.convosBg) {
                window.webkit.messageHandlers.convosBg.postMessage(bg || '');
            }
        }
        postBg();
        window.addEventListener('load', postBg);
    })();
    """

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "convosBg")
        let userScript = WKUserScript(
            source: Self.bgScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onBodyBackgroundColor = onBodyBackgroundColor
        guard context.coordinator.loadedFileURL != fileURL else { return }
        context.coordinator.loadedFileURL = fileURL
        let readAccessURL = fileURL.deletingLastPathComponent()
        webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBodyBackgroundColor: onBodyBackgroundColor)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedFileURL: URL?
        var onBodyBackgroundColor: (UIColor?) -> Void

        init(onBodyBackgroundColor: @escaping (UIColor?) -> Void) {
            self.onBodyBackgroundColor = onBodyBackgroundColor
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                return .allow
            }

            guard let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else {
                return .cancel
            }

            await UIApplication.shared.open(url)
            return .cancel
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "convosBg",
                  let raw = message.body as? String else { return }
            let parsed = Self.parseCSSColor(raw)
            DispatchQueue.main.async { [weak self] in
                self?.onBodyBackgroundColor(parsed)
            }
        }

        private static func parseCSSColor(_ raw: String) -> UIColor? {
            let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let isRGBA = trimmed.hasPrefix("rgba(")
            let prefix = isRGBA ? "rgba(" : "rgb("
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(")") else { return nil }
            let inner = trimmed.dropFirst(prefix.count).dropLast()
            let parts = inner
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3,
                  let r = Double(parts[0]),
                  let g = Double(parts[1]),
                  let b = Double(parts[2]) else { return nil }
            let alpha: Double = parts.count >= 4 ? (Double(parts[3]) ?? 1.0) : 1.0
            if alpha < 0.05 { return nil }
            return UIColor(red: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: alpha)
        }
    }
}

private extension UIColor {
    /// Returns true when the color's relative luminance is below 0.5 (treated as dark).
    var convos_isDark: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        // Standard sRGB relative luminance.
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance < 0.5
    }
}
