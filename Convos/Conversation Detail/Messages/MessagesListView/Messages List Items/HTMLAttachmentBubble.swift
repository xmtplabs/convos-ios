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

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
        }
        .frame(maxWidth: .infinity)
        .frame(height: Constant.cellHeight)
        .background(Color.colorBackgroundSubtle)
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
                HTMLPreviewWebView(fileURL: fileURL, colorScheme: colorScheme)
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
        let topColor: Color = pageBackgroundColor.opacity(0.15)
        let bottomColor: Color = pageBackgroundColor
        LinearGradient(
            colors: [topColor, bottomColor],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Constant.fadeHeight)
        .allowsHitTesting(false)
    }

    private var pageBackgroundColor: Color {
        colorScheme == .dark
            ? .black
            : Color(red: 245.0 / 255.0, green: 245.0 / 255.0, blue: 245.0 / 255.0)
    }

    private var cornerRadius: CGFloat {
        horizontalSizeClass == .regular ? DesignConstants.CornerRadius.medium : 0
    }

    private func loadFile() async {
        guard fileURL == nil else { return }
        do {
            fileURL = try await FileAttachmentLoader.loadFile(for: attachment)
            hasLoadFailed = false
        } catch {
            hasLoadFailed = true
        }
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

    private static let stripTopPaddingScript: String = """
    (function() {
        var css = 'html, body { margin-top: 0 !important; padding-top: 0 !important; } ' +
                  '.note, .table, .note-hero, main, article { padding-top: 0 !important; margin-top: 0 !important; }';
        var style = document.createElement('style');
        style.setAttribute('data-convos-cell-preview', '1');
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
    })();
    """

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userScript = WKUserScript(
            source: Self.stripTopPaddingScript,
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
        webView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        guard context.coordinator.loadedFileURL != fileURL else { return }
        context.coordinator.loadedFileURL = fileURL
        let readAccessURL = fileURL.deletingLastPathComponent()
        webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var loadedFileURL: URL?
    }
}
