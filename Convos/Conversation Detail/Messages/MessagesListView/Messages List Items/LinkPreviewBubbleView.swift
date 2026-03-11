import ConvosCore
import SwiftUI

struct LinkPreviewBubbleView: View {
    let preview: LinkPreview
    let style: MessageBubbleType
    let isOutgoing: Bool
    let profile: Profile

    @Environment(\.messagePressed) private var isPressed: Bool

    var body: some View {
        MessageContainer(style: style, isOutgoing: isOutgoing) {
            LinkPreviewCardView(preview: preview)
                .opacity(isPressed ? 0.7 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isPressed)
        }
    }
}

struct LinkPreviewCardView: View {
    let preview: LinkPreview
    @State private var ogTitle: String?
    @State private var ogImageURL: String?
    @State private var ogSiteName: String?
    @State private var cachedImage: UIImage?
    @State private var imageAspectRatio: CGFloat?
    @State private var hasFetchedMetadata: Bool = false

    private var clampedAspectRatio: CGFloat {
        let ratio = imageAspectRatio ?? 1.91
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
                        .aspectRatio(contentMode: .fit)
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
            .modifier(ImageAreaModifier(hasImage: cachedImage != nil, aspectRatio: clampedAspectRatio))
            .clipped()
            .background(.colorFillMinimal)

            VStack(alignment: .leading, spacing: 2.0) {
                Text(displayTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.black)
                    .font(.callout.weight(.bold))
                    .fontWeight(.bold)
                    .truncationMode(.tail)
                Text(displaySubtitle)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 280.0, alignment: .leading)
        .background(.colorLinkBackground)
        .task {
            await fetchOpenGraphMetadata()
        }
    }

    private func fetchOpenGraphMetadata() async {
        guard !hasFetchedMetadata else { return }
        hasFetchedMetadata = true

        let metadata = await OpenGraphService.shared.fetchMetadata(for: preview.url)

        if let metadata {
            ogTitle = metadata.title
            ogSiteName = metadata.siteName

            if let imageURLString = metadata.imageURL ?? preview.imageURL,
               let imageURL = URL(string: imageURLString) {
                ogImageURL = imageURLString
                await loadImage(from: imageURL)
            }
        } else if let imageURLString = preview.imageURL,
                  let imageURL = URL(string: imageURLString) {
            await loadImage(from: imageURL)
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
            if let image = UIImage(data: data) {
                ImageCache.shared.cacheImage(image, for: cacheKey, storageTier: .persistent)
                cachedImage = image
                imageAspectRatio = image.size.width / image.size.height
            }
        } catch {
            Log.error("Failed to load link preview image")
        }
    }
}

private struct ImageAreaModifier: ViewModifier {
    let hasImage: Bool
    let aspectRatio: CGFloat

    func body(content: Content) -> some View {
        if hasImage {
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
