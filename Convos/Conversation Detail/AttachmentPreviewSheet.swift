import ConvosCore
import ConvosLogging
import ConvosMetrics
import QuickLook
import SwiftUI
import UIKit
import WebKit

struct AttachmentPreviewSheet: View {
    let attachment: HydratedAttachment
    let fileURL: URL
    var sender: ConversationMember?
    let sentAt: Date
    var profileSheetContent: ((ConversationMember) -> AnyView)?

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var resolvedHTMLTitle: String?
    @State private var htmlBodyBackgroundColor: Color?
    @State private var presentingProfileForMember: ConversationMember?
    @State private var sharedImage: UIImage?
    @State private var sharedImageURL: URL?
    @State private var markdownHasContentThumbnail: Bool = false
    @State private var navState: AttachmentPreviewNavigatorImpl = .init()
    @State private var navigator: AttachmentPreviewCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = AttachmentPreviewCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    private func handleMemberSheetChanged(from oldMember: ConversationMember?, to newMember: ConversationMember?) {
        guard oldMember == nil, let newMember else { return }
        navigator?.navigateTo(
            contactCard: ContactCardNavigatorArgs(inboxId: newMember.profile.inboxId)
        )
    }

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
                    if let sender {
                        ToolbarItem(placement: .principal) {
                            let tap: ((ConversationMember) -> Void)? = profileSheetContent == nil
                                ? nil
                                : { tapped in presentingProfileForMember = tapped }
                            AttachmentSenderIndicator(
                                sender: sender,
                                sentAt: sentAt,
                                onTap: tap
                            )
                        }
                    }
                    shareToolbarItem
                }
        }
        .accessibilityElement(children: .contain)
        .sheet(item: $presentingProfileForMember) { member in
            if let profileSheetContent {
                profileSheetContent(member)
            }
        }
        .task(id: attachment.key) {
            await resolveTitleIfNeeded()
            await resolveShareImageIfNeeded()
        }
        .onAppear {
            ensureNavigator()
            navState.markScreenAppeared()
        }
        .onDisappear {
            navigator?.closed(context: navState.closeContext())
        }
        .onChange(of: presentingProfileForMember) { oldMember, newMember in
            handleMemberSheetChanged(from: oldMember, to: newMember)
        }
    }

    private var canShareImage: Bool {
        // QuickLook renders its own bottom share toolbar, so suppress ours when it
        // owns the preview. For HTML and Markdown branches, we share the rendered
        // thumbnail image instead of the underlying file. Markdown only qualifies
        // when QLThumbnailGenerator returns a content thumbnail, not a doc icon.
        if attachment.isHTMLFile { return true }
        if attachment.isMarkdownFile { return markdownHasContentThumbnail }
        return false
    }

    @ToolbarContentBuilder
    private var shareToolbarItem: some ToolbarContent {
        if canShareImage {
            ToolbarItem(placement: .confirmationAction) {
                shareButton
            }
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        let title: String = resolvedHTMLTitle ?? attachment.filename ?? "Image"
        if let url = sharedImageURL, let image = sharedImage {
            let previewImage: Image = Image(uiImage: image)
            ShareLink(item: url, preview: SharePreview(title, image: previewImage)) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
            .accessibilityIdentifier("attachment-preview-share")
        } else {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Share")
                .accessibilityIdentifier("attachment-preview-share")
        }
    }

    private func resolveTitleIfNeeded() async {
        guard attachment.isHTMLFile else { return }
        if let cached = HTMLPageMetadata.shared.cachedTitle(for: attachment.key) {
            resolvedHTMLTitle = cached
            return
        }
        resolvedHTMLTitle = await HTMLPageMetadata.shared.title(for: attachment.key, fileURL: fileURL)
    }

    private func resolveShareImageIfNeeded() async {
        let image: UIImage?
        if attachment.isHTMLFile {
            image = await resolveHTMLShareImage()
        } else if attachment.isMarkdownFile {
            image = await resolveMarkdownShareImage()
        } else {
            return
        }
        guard let image else { return }
        let basename: String = shareImageBasename()
        let url: URL? = await writeSharePNG(image: image, basename: basename)
        sharedImage = image
        sharedImageURL = url
    }

    private func resolveHTMLShareImage() async -> UIImage? {
        let appearance = colorScheme.uiUserInterfaceStyle
        if let cached = HTMLThumbnailRenderer.shared.cachedThumbnail(for: attachment.key, appearance: appearance) {
            return cached
        }
        return await HTMLThumbnailRenderer.shared.thumbnail(
            for: attachment.key,
            fileURL: fileURL,
            appearance: appearance
        )
    }

    private func resolveMarkdownShareImage() async -> UIImage? {
        if let cached = FileThumbnailRenderer.shared.cachedThumbnail(for: attachment.key),
           cached.isContentThumbnail {
            markdownHasContentThumbnail = true
            return cached.image
        }
        guard let result = await FileThumbnailRenderer.shared.thumbnail(for: attachment.key, fileURL: fileURL),
              result.isContentThumbnail else {
            return nil
        }
        markdownHasContentThumbnail = true
        return result.image
    }

    private func shareImageBasename() -> String {
        let raw: String
        if let filename = attachment.filename, !filename.isEmpty {
            raw = (filename as NSString).deletingPathExtension
        } else {
            raw = String(attachment.key.prefix(32))
        }
        return sanitizeFilename(raw)
    }

    private func sanitizeFilename(_ raw: String) -> String {
        let allowed: CharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var output: String = ""
        for scalar in raw.unicodeScalars {
            output.append(allowed.contains(scalar) ? Character(scalar) : "_")
        }
        let trimmed: String = output.isEmpty ? "image" : output
        return String(trimmed.prefix(64))
    }

    private func writeSharePNG(image: UIImage, basename: String) async -> URL? {
        guard let pngData = image.pngData() else {
            Log.error("AttachmentPreviewSheet: failed to encode share image PNG")
            return nil
        }
        let url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("\(basename).png")
        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            Log.error("AttachmentPreviewSheet: failed to write share PNG: \(error)")
            return nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if attachment.isHTMLFile {
            AttachmentHTMLContent(
                fileURL: fileURL,
                attachmentKey: attachment.key,
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
                    useSystemPlaceholder: false,
                    agentVerification: sender.agentVerification
                )
                .frame(width: 36.0, height: 36.0)

                VStack(alignment: .leading, spacing: 0) {
                    Text(sender.profile.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.colorTextPrimary)
                        .frame(maxWidth: 140.0, alignment: .leading)
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("attachment-preview-sender")
    }

    private var accessibilityLabel: String {
        let base = "Sent by \(sender.profile.displayName), \(subtitle)"
        return onTap == nil ? base : "\(base), tap to view profile"
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
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, (1..<7).contains(days) {
            return weekdayFormatter.string(from: date)
        }
        return shortDateFormatter.string(from: date)
    }
}

// MARK: - HTML content

struct AttachmentHTMLContent: UIViewRepresentable {
    let fileURL: URL
    /// Optional attachment key. When provided, `makeUIView` first asks the
    /// `HTMLContentPrewarmer` for a live WebView that's already loaded and
    /// painted - the matched-geometry zoom transition then lands on real
    /// content instead of waiting on a fresh `WKWebView.loadFileURL`.
    var attachmentKey: String?
    var onBodyBackgroundColor: ((Color?) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        if let key = attachmentKey,
           let prewarmed = HTMLContentPrewarmer.shared.borrowContent(for: key) {
            // Prewarmed WebView still has the `PrewarmCoordinator`
            // wired as its navigation delegate and as the listener on
            // the `convosBg` script handler. Re-point both at the
            // sheet's coordinator so link taps now route through
            // `InAppBrowser.open(...)` and any subsequent bg-color
            // posts land on `onBodyBackgroundColor` instead of the
            // stale prewarm coordinator.
            let controller = prewarmed.webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: HTMLBodyBackgroundBridge.messageHandlerName)
            controller.add(context.coordinator, name: HTMLBodyBackgroundBridge.messageHandlerName)
            prewarmed.webView.navigationDelegate = context.coordinator
            context.coordinator.usingPrewarmedWebView = true
            context.coordinator.loadedFileURL = fileURL
            DispatchQueue.main.async {
                self.onBodyBackgroundColor?(prewarmed.bodyBackgroundColor)
            }
            return prewarmed.webView
        }
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: HTMLBodyBackgroundBridge.messageHandlerName)
        config.userContentController.addUserScript(HTMLBodyBackgroundBridge.makeUserScript())
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onBodyBackgroundColor = onBodyBackgroundColor
        // Prewarmed WebViews already loaded the same file during their
        // off-screen warm-up; calling `loadFileURL` here would discard
        // the painted DOM and trigger a fresh load, defeating the prewarm.
        if context.coordinator.usingPrewarmedWebView { return }
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
        /// True when `makeUIView` returned a `WKWebView` borrowed from
        /// the prewarmer. The pre-load has already happened, so
        /// `updateUIView` skips its `loadFileURL` path to avoid kicking
        /// off a redundant second load that would blank out the view.
        var usingPrewarmedWebView: Bool = false

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
            InAppBrowser.open(url)
            return .cancel
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == HTMLBodyBackgroundBridge.messageHandlerName,
                  let raw = message.body as? String else { return }
            let parsed = HTMLBodyBackgroundBridge.parseCSSColor(raw)
            DispatchQueue.main.async { [weak self] in
                self?.onBodyBackgroundColor?(parsed)
            }
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
            InAppBrowser.open(url)
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
        let nav = HiddenBarNavigationController(rootViewController: preview)
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

private final class HiddenBarNavigationController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        super.setNavigationBarHidden(true, animated: false)
    }

    override func setNavigationBarHidden(_ hidden: Bool, animated: Bool) {
        super.setNavigationBarHidden(true, animated: false)
    }
}
