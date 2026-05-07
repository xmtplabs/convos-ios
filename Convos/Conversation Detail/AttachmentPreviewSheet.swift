import ConvosCore
import ConvosLogging
import QuickLook
import SwiftUI
import UIKit
import WebKit

struct AttachmentPreviewSheet: View {
    let attachment: HydratedAttachment
    let fileURL: URL
    let sender: ConversationMember
    let sentAt: Date
    var profileSheetContent: ((ConversationMember) -> AnyView)?

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var resolvedHTMLTitle: String?
    @State private var htmlBodyBackgroundColor: Color?
    @State private var presentingProfileForMember: ConversationMember?

    var body: some View {
        NavigationStack {
            content
                .background(htmlBodyBackgroundColor ?? Color.clear)
                .ignoresSafeArea()
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        let action = { dismiss() }
                        Button(action: action) {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("attachment-preview-close")
                    }
                    ToolbarItem(placement: .principal) {
                        AttachmentSenderIndicator(
                            sender: sender,
                            sentAt: sentAt,
                            onTap: { tapped in presentingProfileForMember = tapped }
                        )
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: fileURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share")
                        .accessibilityIdentifier("attachment-preview-share")
                    }
                }
        }
        .accessibilityElement(children: .contain)
        .sheet(item: $presentingProfileForMember) { member in
            if let profileSheetContent {
                profileSheetContent(member)
            }
        }
        .task(id: attachment.key) {
            guard attachment.isHTMLFile else { return }
            if let cached = HTMLPageMetadata.shared.cachedTitle(for: attachment.key) {
                resolvedHTMLTitle = cached
                return
            }
            resolvedHTMLTitle = await HTMLPageMetadata.shared.title(for: attachment.key, fileURL: fileURL)
        }
    }

    @ViewBuilder
    private var content: some View {
        if attachment.isHTMLFile {
            AttachmentHTMLContent(
                fileURL: fileURL,
                onBodyBackgroundColor: { color in
                    htmlBodyBackgroundColor = color
                }
            )
        } else if attachment.isMarkdownFile {
            AttachmentMarkdownContent(fileURL: fileURL)
        } else {
            AttachmentQuickLookContent(fileURL: fileURL)
        }
    }
}

// MARK: - Sender indicator

private struct AttachmentSenderIndicator: View {
    let sender: ConversationMember
    let sentAt: Date
    var onTap: ((ConversationMember) -> Void)?

    private var subtitle: String {
        Self.formatter.string(for: sentAt)
    }

    private static let formatter: SentDateFormatter = SentDateFormatter()

    var body: some View {
        let action: () -> Void = {
            onTap?(sender)
        }
        Button(action: action) {
            HStack(spacing: 0) {
                ProfileAvatarView(
                    profile: sender.profile,
                    profileImage: nil,
                    useSystemPlaceholder: false
                )
                .frame(width: 36.0, height: 36.0)

                VStack(alignment: .leading, spacing: 0) {
                    Text(sender.profile.displayName)
                        .lineLimit(1)
                        .frame(maxWidth: 140.0, alignment: .leading)
                        .font(.callout.weight(.medium))
                        .truncationMode(.tail)
                        .foregroundStyle(.colorTextPrimary)
                        .fixedSize()
                    Text(subtitle)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
                .padding(.horizontal, DesignConstants.Spacing.step2x)
            }
            .padding(DesignConstants.Spacing.step2x)
            .fixedSize(horizontal: true, vertical: true)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sent by \(sender.profile.displayName), \(subtitle), tap to view profile")
    }
}

private struct SentDateFormatter {
    private let calendar: Calendar = .current
    private let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()
    private let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    func string(for date: Date) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return weekdayFormatter.string(from: date)
        }
        return shortDateFormatter.string(from: date)
    }
}

// MARK: - HTML content

private struct AttachmentHTMLContent: UIViewRepresentable {
    let fileURL: URL
    var onBodyBackgroundColor: ((Color?) -> Void)?

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
        var onBodyBackgroundColor: ((Color?) -> Void)?

        init(onBodyBackgroundColor: ((Color?) -> Void)?) {
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
                self?.onBodyBackgroundColor?(parsed)
            }
        }

        private static func parseCSSColor(_ raw: String) -> Color? {
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
            return Color(.sRGB, red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: alpha)
        }
    }
}

// MARK: - Markdown content

private struct AttachmentMarkdownContent: View {
    let fileURL: URL

    @State private var htmlString: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let htmlString {
                MarkdownWebView(html: htmlString)
                    .ignoresSafeArea(edges: .bottom)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "doc.text",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await loadMarkdown()
        }
    }

    private func loadMarkdown() async {
        guard let markedJS = Self.loadMarkedJS() else {
            errorMessage = "Markdown renderer is unavailable."
            return
        }
        do {
            let url = fileURL
            let markdown = try await Task.detached {
                try String(contentsOf: url, encoding: .utf8)
            }.value
            let encodedMarkdown = Data(markdown.utf8).base64EncodedString()
            htmlString = Self.htmlTemplate(markedJS: markedJS, encodedMarkdown: encodedMarkdown)
        } catch {
            errorMessage = "This markdown file could not be loaded."
        }
    }

    private static func loadMarkedJS() -> String? {
        guard let url = Bundle.main.url(forResource: "marked.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return js
    }

    private static func htmlTemplate(markedJS: String, encodedMarkdown: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1" />
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;" />
        <style>
            :root { color-scheme: light dark; }
            body {
                font: -apple-system-body;
                font-family: -apple-system, system-ui, sans-serif;
                padding: 16px;
                line-height: 1.6;
                word-wrap: break-word;
                overflow-wrap: break-word;
            }
            h1 { font-size: 1.6em; margin-top: 0; }
            h2 { font-size: 1.4em; }
            h3 { font-size: 1.2em; }
            code {
                font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                font-size: 0.9em;
                background: rgba(128, 128, 128, 0.15);
                padding: 2px 5px;
                border-radius: 4px;
            }
            pre {
                background: rgba(128, 128, 128, 0.1);
                padding: 12px;
                border-radius: 8px;
                overflow-x: auto;
            }
            pre code {
                background: none;
                padding: 0;
            }
            blockquote {
                border-left: 3px solid rgba(128, 128, 128, 0.4);
                margin-left: 0;
                padding-left: 16px;
                color: rgba(128, 128, 128, 0.8);
            }
            img { max-width: 100%; height: auto; }
            table {
                border-collapse: collapse;
                width: 100%;
            }
            th, td {
                border: 1px solid rgba(128, 128, 128, 0.3);
                padding: 8px;
                text-align: left;
            }
            a { color: #007AFF; }
            @media (prefers-color-scheme: dark) {
                a { color: #0A84FF; }
            }
        </style>
        <script>\(markedJS)</script>
        </head>
        <body data-markdown="\(encodedMarkdown)">
        <div id="content"></div>
        <script>
            var encoded = document.body.getAttribute('data-markdown');
            var decoded = atob(encoded);
            var text = new TextDecoder().decode(Uint8Array.from(decoded, function(c) { return c.charCodeAt(0); }));
            var renderer = { html: function(token) { return ''; } };
            marked.use({ renderer: renderer });
            var html = marked.parse(text);
            var div = document.createElement('div');
            div.innerHTML = html;
            div.querySelectorAll('script, iframe, object, embed, form, input, textarea, button, select').forEach(function(el) { el.remove(); });
            div.querySelectorAll('*').forEach(function(el) {
                el.getAttributeNames().filter(function(n) { return n.startsWith('on'); }).forEach(function(n) { el.removeAttribute(n); });
            });
            div.querySelectorAll('a').forEach(function(el) {
                var href = el.getAttribute('href');
                if (!href) {
                    return;
                }
                try {
                    var parsed = new URL(href, 'https://example.invalid');
                    var scheme = parsed.protocol.toLowerCase();
                    if (scheme !== 'http:' && scheme !== 'https:' && scheme !== 'mailto:') {
                        el.removeAttribute('href');
                    }
                } catch (e) {
                    el.removeAttribute('href');
                }
            });
            document.getElementById('content').innerHTML = div.innerHTML;
        </script>
        </body>
        </html>
        """
    }
}

private struct MarkdownWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

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
    }
}

// MARK: - Generic file content (QuickLook)

private struct AttachmentQuickLookContent: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        let nav = UINavigationController(rootViewController: preview)
        nav.isNavigationBarHidden = true
        nav.setToolbarHidden(true, animated: false)
        return nav
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.fileURL = fileURL
        if let preview = controller.viewControllers.first as? QLPreviewController {
            preview.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            fileURL as NSURL
        }
    }
}
