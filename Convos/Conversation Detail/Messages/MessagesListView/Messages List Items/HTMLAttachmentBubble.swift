import ConvosCore
import SwiftUI
import WebKit

struct HTMLAttachmentBubble: View {
    let attachment: HydratedAttachment
    let profile: Profile
    let reactions: [MessageReaction]
    var onTapAvatar: (() -> Void)?
    var onTapReactions: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @State private var fileURL: URL?
    @State private var hasLoadFailed: Bool = false
    @State private var bodyBackgroundColor: Color?

    private static let bodyBackgroundCache: NSCache<NSString, UIColor> = {
        let cache = NSCache<NSString, UIColor>()
        cache.countLimit = 64
        return cache
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
        }
        .frame(maxWidth: .infinity)
        .frame(height: Constant.cellHeight)
        .background(Color.colorBackgroundSurfaceless)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(alignment: .bottom) {
            bottomFade
        }
        .overlay(alignment: .bottomLeading) {
            if !reactions.isEmpty {
                let tap: () -> Void = {
                    onTapReactions?()
                }
                MediaContainerReax(reactions: reactions, onTap: tap)
            }
        }
        .accessibilityIdentifier("html-attachment-bubble")
        .accessibilityLabel("HTML page from \(profile.displayName)")
        .task(id: attachment.key) {
            await loadFile()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            senderTapTarget
            Spacer()
            viewAffordance
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .frame(height: Constant.headerHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Color.colorBorderSubtle
                .frame(height: Constant.borderHeight)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
        }
    }

    @ViewBuilder
    private var senderTapTarget: some View {
        let tap: () -> Void = {
            onTapAvatar?()
        }
        Button(action: tap) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                ProfileAvatarView(
                    profile: profile,
                    profileImage: nil,
                    useSystemPlaceholder: false
                )
                .frame(width: DesignConstants.ImageSizes.smallAvatar, height: DesignConstants.ImageSizes.smallAvatar)
                Text(profile.displayName)
                    .font(.footnote)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)
                    .accessibilityIdentifier("html-attachment-bubble-sender")
            }
        }
        .buttonStyle(.plain)
        .background(GesturePassthroughBackground())
        .accessibilityLabel("View \(profile.displayName)'s profile")
    }

    @ViewBuilder
    private var viewAffordance: some View {
        HStack(spacing: 4) {
            Text("View")
                .font(.footnote)
            Image(systemName: "chevron.right")
                .font(.footnote)
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var preview: some View {
        if let fileURL {
            GeometryReader { proxy in
                let scale: CGFloat = proxy.size.width > 0 ? proxy.size.width / Constant.renderWidth : 1
                let logicalHeight: CGFloat = scale > 0 ? proxy.size.height / scale : Constant.renderWidth
                HTMLPreviewWebView(
                    fileURL: fileURL,
                    colorScheme: colorScheme,
                    onBodyBackgroundColor: { color in
                        cache(color, for: attachment.key)
                        bodyBackgroundColor = color
                    }
                )
                .frame(width: Constant.renderWidth, height: logicalHeight)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
            }
            .allowsHitTesting(false)
        } else {
            ZStack {
                Rectangle().fill(Color.colorFillMinimal)
                if hasLoadFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
    }

    @ViewBuilder
    private var bottomFade: some View {
        let endColor: Color = bodyBackgroundColor ?? .clear
        LinearGradient(
            colors: [endColor.opacity(0), endColor],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Constant.fadeHeight)
        .allowsHitTesting(false)
    }

    private var cornerRadius: CGFloat {
        horizontalSizeClass == .regular ? DesignConstants.CornerRadius.medium : 0
    }

    private func loadFile() async {
        if bodyBackgroundColor == nil,
           let cached = HTMLAttachmentBubble.bodyBackgroundCache.object(forKey: attachment.key as NSString) {
            bodyBackgroundColor = Color(uiColor: cached)
        }
        guard fileURL == nil else { return }
        do {
            fileURL = try await FileAttachmentLoader.loadFile(for: attachment)
            hasLoadFailed = false
        } catch {
            hasLoadFailed = true
        }
    }

    private func cache(_ color: Color?, for key: String) {
        guard let color else { return }
        HTMLAttachmentBubble.bodyBackgroundCache.setObject(UIColor(color), forKey: key as NSString)
    }

    private enum Constant {
        static let renderWidth: CGFloat = 720.0
        static let headerHeight: CGFloat = 56.0
        static let cellHeight: CGFloat = 500.0
        static let fadeHeight: CGFloat = 68.0
        static let borderHeight: CGFloat = 1.0
    }
}

private struct HTMLPreviewWebView: UIViewRepresentable {
    let fileURL: URL
    let colorScheme: ColorScheme
    let onBodyBackgroundColor: (Color?) -> Void

    private static let cellPreviewScript: String = """
    (function() {
        var css = 'html, body { margin-top: 0 !important; padding-top: 0 !important; } ' +
                  '.note, .table, .note-hero, main, article { padding-top: 0 !important; margin-top: 0 !important; }';
        var style = document.createElement('style');
        style.setAttribute('data-convos-cell-preview', '1');
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);

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
            source: Self.cellPreviewScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = true
        webView.isUserInteractionEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onBodyBackgroundColor = onBodyBackgroundColor
        webView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        guard context.coordinator.loadedFileURL != fileURL else { return }
        context.coordinator.loadedFileURL = fileURL
        let readAccessURL = fileURL.deletingLastPathComponent()
        webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBodyBackgroundColor: onBodyBackgroundColor)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onBodyBackgroundColor: (Color?) -> Void
        var loadedFileURL: URL?

        init(onBodyBackgroundColor: @escaping (Color?) -> Void) {
            self.onBodyBackgroundColor = onBodyBackgroundColor
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "convosBg",
                  let raw = message.body as? String else { return }
            let parsed = HTMLPreviewWebView.parseCSSColor(raw)
            DispatchQueue.main.async {
                self.onBodyBackgroundColor(parsed)
            }
        }
    }

    static func parseCSSColor(_ raw: String) -> Color? {
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
