import ConvosCore
import SwiftUI

struct ArtifactBubble: View {
    let attachment: HydratedAttachment
    let style: MessageBubbleType
    let isOutgoing: Bool

    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var bundle: ArtifactBundle?
    @State private var previewImage: UIImage?
    @State private var hasLoadFailed: Bool = false

    var body: some View {
        MessageContainer(style: style, isOutgoing: isOutgoing) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                    .frame(width: Constant.previewSize, height: Constant.previewSize)
                    .clipped()
                captionRow
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .padding(.vertical, DesignConstants.Spacing.step2x)
            }
            .frame(width: Constant.previewSize)
        }
        .accessibilityIdentifier("artifact-bubble")
        .accessibilityLabel("Artifact: \(displayTitle)")
        .task(id: colorScheme) {
            await loadIfNeeded()
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderBackground
                placeholderContent
            }
        }
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

    private func loadIfNeeded() async {
        previewImage = nil

        let resolvedBundle: ArtifactBundle
        if let bundle {
            resolvedBundle = bundle
        } else {
            do {
                resolvedBundle = try await ArtifactBundleStore.shared.bundle(
                    for: attachment.key,
                    filename: attachment.filename
                )
                bundle = resolvedBundle
                hasLoadFailed = false
            } catch {
                hasLoadFailed = true
                return
            }
        }

        let mode: ArtifactPreviewSnapshotter.Mode = colorScheme == .dark ? .dark : .light
        let cacheKey = Self.previewCacheKey(hash: resolvedBundle.previewHash, mode: mode)

        if let cached = await ImageCache.shared.imageAsync(for: cacheKey, imageFormat: .png) {
            previewImage = cached
            return
        }

        do {
            let html = try String(contentsOf: resolvedBundle.previewHTMLURL, encoding: .utf8)
            let image = try await ArtifactPreviewSnapshotter.snapshot(html: html, mode: mode)
            ImageCache.shared.cacheImage(image, for: cacheKey, imageFormat: .png)
            previewImage = image
        } catch {
            hasLoadFailed = true
        }
    }

    private static func previewCacheKey(hash: String, mode: ArtifactPreviewSnapshotter.Mode) -> String {
        "artifact-preview:\(hash):\(mode.rawValue)"
    }

    private enum Constant {
        static let previewSize: CGFloat = 260.0
    }
}
