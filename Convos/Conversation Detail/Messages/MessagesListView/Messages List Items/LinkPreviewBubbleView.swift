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
    @State private var ogDescription: String?
    @State private var ogImageURL: String?
    @State private var ogSiteName: String?
    @State private var cachedImage: UIImage?
    @State private var imageAspectRatio: CGFloat?
    @State private var authorAvatarURL: String?
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

    private var socialBodyText: String {
        if let description = ogDescription ?? preview.description, !description.isEmpty {
            return description
        }
        if let postContent = extractPostContent() {
            return postContent
        }
        return ogTitle ?? preview.title ?? preview.displayHost
    }

    private func extractPostContent() -> String? {
        guard let title = ogTitle ?? preview.title else { return nil }
        let patterns = [" on X: ", " on Twitter: ", " on Threads: ", " on Bluesky: "]
        for pattern in patterns {
            if let range = title.range(of: pattern) {
                let content = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if content.hasPrefix("\""), content.hasSuffix("\""), content.count > 2 {
                    return String(content.dropFirst().dropLast())
                }
                return content.isEmpty ? nil : content
            }
        }
        return nil
    }

    var body: some View {
        Group {
            if let platform = preview.socialPlatform {
                SocialPostCardView(
                    platform: platform,
                    username: preview.socialUsername,
                    authorName: socialAuthorName,
                    bodyText: socialBodyText,
                    image: cachedImage,
                    imageAspectRatio: imageAspectRatio,
                    authorAvatarURL: authorAvatarURL
                )
            } else {
                genericCardBody
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Link preview: \(displayTitle)")
        .accessibilityHint("Opens \(preview.displayHost)")
        .task {
            await fetchOpenGraphMetadata()
        }
    }

    private var socialAuthorName: String? {
        guard let title = ogTitle ?? preview.title else { return nil }
        let suffixes = [" on X:", " on X", " on Twitter:", " on Twitter", " on Threads:", " on Threads", " on Bluesky:", " on Bluesky"]
        for suffix in suffixes {
            if let range = title.range(of: suffix) {
                var name = String(title[title.startIndex ..< range.lowerBound])
                if let parenRange = name.range(of: " (@") {
                    name = String(name[name.startIndex ..< parenRange.lowerBound])
                }
                return name.isEmpty ? nil : name
            }
        }
        if let parenRange = title.range(of: " (@"),
           parenRange.lowerBound > title.startIndex {
            let name = String(title[title.startIndex ..< parenRange.lowerBound])
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private var genericCardBody: some View {
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
            .background(.colorBackgroundMedia)

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 280.0, alignment: .leading)
        .background(.colorFillSubtle)
    }

    private func fetchOpenGraphMetadata() async {
        guard !hasFetchedMetadata else { return }

        let metadata = await OpenGraphService.shared.fetchMetadata(for: preview.url)

        if let metadata {
            ogTitle = metadata.title
            ogDescription = metadata.description
            ogSiteName = metadata.siteName
            authorAvatarURL = metadata.authorAvatarURL

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
                description: metadata.description,
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
        if let image = await OpenGraphService.shared.loadImage(from: url) {
            ImageCache.shared.cacheImage(image, for: cacheKey, storageTier: .cache)
            cachedImage = image
            imageAspectRatio = image.size.width / image.size.height
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
