import ConvosCore
import SwiftUI
import WebKit

struct MCPAppWebView: UIViewRepresentable {
    let htmlContent: String
    let baseURL: URL?
    let allowedDomains: [String]
    @Binding var contentHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController = createUserContentController(coordinator: context.coordinator)
        config.preferences.isElementFullscreenEnabled = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let sandboxRules: String = [
            "allow-scripts",
            "allow-same-origin"
        ].joined(separator: " ")
        config.setValue(sandboxRules, forKey: "sandboxValue")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.isInspectable = false

        #if DEBUG
        webView.isInspectable = true
        #endif

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let wrappedHTML = wrapHTMLWithTheme(htmlContent)
        webView.loadHTMLString(wrappedHTML, baseURL: baseURL)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
    }

    private func createUserContentController(coordinator: Coordinator) -> WKUserContentController {
        let controller = WKUserContentController()
        controller.add(coordinator, name: Constant.heightMessageHandler)

        let csp = buildCSP()
        let metaTag = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
        let cspScript = WKUserScript(
            source: """
                var meta = document.createElement('meta');
                meta.httpEquiv = 'Content-Security-Policy';
                meta.content = '\(csp)';
                document.head.prepend(meta);
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(cspScript)

        let heightObserver = WKUserScript(
            source: """
                (function() {
                    function reportHeight() {
                        var height = document.documentElement.scrollHeight;
                        window.webkit.messageHandlers.\(Constant.heightMessageHandler).postMessage(height);
                    }
                    new ResizeObserver(reportHeight).observe(document.documentElement);
                    reportHeight();
                })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(heightObserver)

        return controller
    }

    private func buildCSP() -> String {
        var directives: [String] = [
            "default-src 'none'",
            "script-src 'unsafe-inline'",
            "style-src 'unsafe-inline'",
            "img-src data: blob:"
        ]

        if !allowedDomains.isEmpty {
            let filtered = allowedDomains.filter { !$0.contains("*") }
            if !filtered.isEmpty {
                let domainList = filtered.joined(separator: " ")
                directives.append("connect-src \(domainList)")
            }
        }

        directives.append("frame-src 'none'")
        directives.append("object-src 'none'")
        directives.append("base-uri 'none'")
        directives.append("form-action 'none'")

        return directives.joined(separator: "; ")
    }

    private func wrapHTMLWithTheme(_ html: String) -> String {
        let displayMode = colorScheme == .dark ? "dark" : "light"

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                :root {
                    --mcp-color-primary: \(colorScheme == .dark ? "#FFFFFF" : "#000000");
                    --mcp-color-text: \(colorScheme == .dark ? "#FFFFFF" : "#000000");
                    --mcp-color-background: \(colorScheme == .dark ? "#000000" : "#FFFFFF");
                    --mcp-color-secondary: \(colorScheme == .dark ? "rgba(255,255,255,0.6)" : "rgba(0,0,0,0.6)");
                    --mcp-color-border: \(colorScheme == .dark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.15)");
                    --mcp-font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
                    --mcp-font-size-base: 16px;
                    --mcp-border-radius: 12px;
                    --mcp-spacing-unit: 8px;
                    --mcp-display-mode: \(displayMode);
                    color-scheme: \(displayMode);
                }
                * { box-sizing: border-box; }
                body {
                    margin: 0;
                    padding: 8px;
                    font-family: var(--mcp-font-family);
                    font-size: var(--mcp-font-size-base);
                    color: var(--mcp-color-text);
                    background: transparent;
                    -webkit-text-size-adjust: none;
                    overflow: hidden;
                }
            </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: MCPAppWebView

        init(parent: MCPAppWebView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Constant.heightMessageHandler,
                  let height = message.body as? CGFloat,
                  height > 0 else { return }

            DispatchQueue.main.async { [weak self] in
                self?.parent.contentHeight = height
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            switch navigationAction.navigationType {
            case .linkActivated:
                if let url = navigationAction.request.url {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            case .other where navigationAction.request.url?.scheme == "about"
                || navigationAction.request.url?.absoluteString == "about:blank":
                decisionHandler(.allow)
            case .other:
                decisionHandler(.allow)
            default:
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.error("MCPAppWebView navigation failed: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            Log.error("MCPAppWebView provisional navigation failed: \(error.localizedDescription)")
        }
    }

    private enum Constant {
        static let heightMessageHandler: String = "mcpHeightReport"
    }
}
