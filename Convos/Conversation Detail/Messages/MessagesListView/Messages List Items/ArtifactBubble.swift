import ConvosCore
import SwiftUI
import WebKit

struct ArtifactBubble: View {
    let attachment: HydratedAttachment
    let style: MessageBubbleType
    let isOutgoing: Bool

    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @State private var bundle: ArtifactBundle?
    @State private var hasLoadFailed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            captionRow
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, DesignConstants.Spacing.step2x)
        }
        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
        .background(bubbleBackground)
        .compositingGroup()
        .clipShape(bubbleShape)
        .accessibilityIdentifier("artifact-bubble")
        .accessibilityLabel("Artifact: \(displayTitle)")
        .task(id: attachment.key) {
            await loadBundle()
        }
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            if let bundle {
                GeometryReader { proxy in
                    let scale: CGFloat = proxy.size.width / Constant.renderSize
                    ArtifactPreviewWebView(fileURL: bundle.previewHTMLURL, colorScheme: colorScheme)
                        .frame(width: Constant.renderSize, height: Constant.renderSize)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                        .clipped()
                }
                .allowsHitTesting(false)
            } else {
                ZStack {
                    placeholderBackground
                    placeholderContent
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private var placeholderBackground: some View {
        Rectangle()
            .fill(isOutgoing ? Color.white.opacity(0.15) : Color.colorFillMinimal)
    }

    @ViewBuilder
    private var placeholderContent: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            if hasLoadFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(secondaryTextColor)
            } else {
                ProgressView()
            }
            Text(displayTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
        }
    }

    @ViewBuilder
    private var captionRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(textColor)
                .lineLimit(2)
                .accessibilityIdentifier("artifact-bubble-title")
            if let summary = bundle?.manifest.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(2)
                    .accessibilityIdentifier("artifact-bubble-summary")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayTitle: String {
        bundle?.manifest.title ?? attachment.filename ?? "Artifact"
    }

    private var textColor: Color {
        isOutgoing ? .colorTextPrimaryInverted : .colorTextPrimary
    }

    private var secondaryTextColor: Color {
        isOutgoing ? .colorTextPrimaryInverted.opacity(0.7) : .secondary
    }

    private var bubbleBackground: Color {
        isOutgoing ? .colorBubble : .colorBubbleIncoming
    }

    private var maxBubbleWidth: CGFloat? {
        horizontalSizeClass == .regular ? Constant.iPadMaxWidth : .infinity
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let radius: CGFloat = Constant.cornerRadius
        let tailRadius: CGFloat = Constant.tailCornerRadius
        switch style {
        case .normal:
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius
            )
        case .tailed where isOutgoing:
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: tailRadius,
                topTrailingRadius: radius
            )
        case .tailed:
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: tailRadius,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius
            )
        case .none:
            return UnevenRoundedRectangle(cornerRadii: .init())
        }
    }

    private func loadBundle() async {
        guard bundle == nil else { return }
        do {
            bundle = try await ArtifactBundleStore.shared.bundle(
                for: attachment.key,
                filename: attachment.filename
            )
            hasLoadFailed = false
        } catch {
            hasLoadFailed = true
        }
    }

    private enum Constant {
        static let renderSize: CGFloat = 1400.0
        static let iPadMaxWidth: CGFloat = 700.0
        static let cornerRadius: CGFloat = 20.0
        static let tailCornerRadius: CGFloat = 4.0
    }
}

private struct ArtifactPreviewWebView: UIViewRepresentable {
    let fileURL: URL
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
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
