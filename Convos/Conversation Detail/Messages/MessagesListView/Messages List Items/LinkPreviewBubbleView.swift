import ConvosCore
import SwiftUI

struct LinkPreviewBubbleView: View {
    let preview: LinkPreview
    let style: MessageBubbleType
    let isOutgoing: Bool
    let profile: Profile
    var messageId: String?

    @Environment(\.messagePressed) private var isPressed: Bool

    var body: some View {
        MessageContainer(style: style, isOutgoing: isOutgoing) {
            LinkPreviewCardView(preview: preview, messageId: messageId)
                .opacity(isPressed ? 0.7 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isPressed)
        }
    }
}

struct LinkPreviewCardView: View {
    let preview: LinkPreview
    var messageId: String?
    @State private var ogTitle: String?
    @State private var ogImageURL: String?
    @State private var ogSiteName: String?
    @State private var cachedImage: UIImage?
    @State private var imageAspectRatio: CGFloat?
    @State private var hasFetchedMetadata: Bool = false

    private var clampedAspectRatio: CGFloat {
        let ratio = imageAspectRatio ?? preview.imageAspectRatio ?? 1.91
        return min(max(ratio, 0.75), 2.0)
    }

    private var displayTitle: String {
        ogTitle ?? preview.title ?? preview.displayHost
    }

    private var displaySubtitle: String {
        let siteName = ogSiteName ?? preview.siteName
        if let siteName, siteName.lowercased() != displayTitle.lowercased() {
            return siteName
        }
        return preview.displayHost
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0.0) {
            ZStack {
                if let image = cachedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blendMode(.multiply)
                } else if hasFetchedMetadata {
                    EmptyView()
                } else {
                    Image(systemName: "link")
                        .font(.largeTitle)
                        .foregroundStyle(.colorTextSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 100.0)
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(ImageAreaModifier(hasKnownRatio: cachedImage != nil || preview.imageAspectRatio != nil, aspectRatio: clampedAspectRatio))
            .clipped()
            .background(.colorLinkBackground)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text(displayTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.colorTextPrimary)
                    .font(.callout.weight(.medium))
                    .truncationMode(.tail)
                Text(displaySubtitle)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 280.0, alignment: .leading)
        .background(.colorFillSubtle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Link preview: \(displayTitle)")
        .accessibilityHint("Opens \(preview.displayHost)")
        .task {
            await fetchOpenGraphMetadata()
        }
    }

    private func fetchOpenGraphMetadata() async {
        guard !hasFetchedMetadata else { return }

        let metadata = await OpenGraphService.shared.fetchMetadata(for: preview.url)

        if let metadata {
            ogTitle = metadata.title
            ogSiteName = metadata.siteName

            if let w = metadata.imageWidth, let h = metadata.imageHeight, w > 0, h > 0 {
                imageAspectRatio = CGFloat(w) / CGFloat(h)
            }

            if let imageURLString = metadata.imageURL ?? preview.imageURL,
               let imageURL = URL(string: imageURLString) {
                ogImageURL = imageURLString
                await loadImage(from: imageURL)
            }
        } else if let imageURLString = preview.imageURL,
                  let imageURL = URL(string: imageURLString) {
            await loadImage(from: imageURL)
        }

        hasFetchedMetadata = true

        if let metadata, let messageId,
           preview.imageWidth == nil || preview.title == nil {
            let enriched = preview.enriched(
                title: metadata.title,
                imageURL: metadata.imageURL,
                siteName: metadata.siteName,
                imageWidth: metadata.imageWidth,
                imageHeight: metadata.imageHeight
            )
            await LinkPreviewWriter.shared?.updateLinkPreview(enriched, forMessageId: messageId)
        }
    }

    private func loadImage(from url: URL) async {
        let cacheKey = url.absoluteString
        if let cached = await ImageCache.shared.imageAsync(for: cacheKey) {
            cachedImage = cached
            imageAspectRatio = cached.size.width / cached.size.height
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard OpenGraphService.isValidImageData(data) else {
                Log.warning("Link preview image rejected: invalid format or size")
                return
            }
            if let image = UIImage(data: data),
               OpenGraphService.isValidImageSize(width: image.size.width, height: image.size.height) {
                ImageCache.shared.cacheImage(image, for: cacheKey, storageTier: .cache)
                cachedImage = image
                imageAspectRatio = image.size.width / image.size.height
            }
        } catch {
            Log.error("Failed to load link preview image")
        }
    }
}

private struct ImageAreaModifier: ViewModifier {
    let hasKnownRatio: Bool
    let aspectRatio: CGFloat

    func body(content: Content) -> some View {
        if hasKnownRatio {
            content.aspectRatio(aspectRatio, contentMode: .fit)
        } else {
            content
        }
    }
}

#Preview("Link Preview - Outgoing") {
    LinkPreviewBubbleView(
        preview: .mock,
        style: .tailed,
        isOutgoing: true,
        profile: .mock()
    )
    .padding()
}

#Preview("Link Preview - Incoming") {
    LinkPreviewBubbleView(
        preview: .mock,
        style: .normal,
        isOutgoing: false,
        profile: .mock()
    )
    .padding()
}

#Preview("Link Preview - No Image") {
    LinkPreviewBubbleView(
        preview: LinkPreview(url: "https://example.com", title: "Example Page"),
        style: .tailed,
        isOutgoing: false,
        profile: .mock()
    )
    .padding()
}
