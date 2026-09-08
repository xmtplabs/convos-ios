#if canImport(UIKit)
import ConvosCore
import SwiftUI

struct LinkPreviewBubbleView: View {
    let preview: LinkPreview
    let style: MessageBubbleType
    let isOutgoing: Bool
    let profile: Profile
    var messageId: String?
    /// When the message carrying this link was sent, which is when the page it
    /// points at was last written. Drives the "Updated ..." line on a link
    /// home; nil elsewhere, and the card falls back to the host.
    var sentAt: Date?

    @Environment(\.messagePressed) private var isPressed: Bool

    var body: some View {
        MessageContainer(style: style, isOutgoing: isOutgoing) {
            LinkPreviewCardView(preview: preview, messageId: messageId, sentAt: sentAt)
                .opacity(isPressed ? 0.7 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isPressed)
        }
    }
}

struct LinkPreviewCardView: View {
    let preview: LinkPreview
    var messageId: String?
    var sentAt: Date?
    /// The conversation's own Space, injected at the cell. Present only inside
    /// a conversation that has one.
    @Environment(\.conversationSpaceURL) private var conversationSpaceURL: URL?
    @State private var ogTitle: String?
    @State private var ogImageURL: String?
    @State private var ogSiteName: String?
    @State private var cachedImage: UIImage?
    @State private var spaceSnapshot: UIImage?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var imageAspectRatio: CGFloat?
    @State private var hasFetchedMetadata: Bool = false

    private var clampedAspectRatio: CGFloat {
        let ratio = imageAspectRatio ?? preview.imageAspectRatio ?? 1.91
        return min(max(ratio, 0.75), 2.0)
    }

    private var displayTitle: String {
        ogTitle ?? preview.title ?? preview.displayHost
    }

    /// Whether this card has an image on the way, and so should hold a place
    /// for one.
    ///
    /// Only a preview that already names an image reserves the slot. The
    /// placeholder used to stand in for every unfetched card and was taken away
    /// again when the fetch found nothing, which shrank the card by the height
    /// of the placeholder after it had been measured. A Space page names no
    /// image today, so that was every card an agent posts.
    private var expectsImage: Bool {
        // A Space page always has a picture coming - its own - so the slot is
        // held from the first layout rather than appearing under the title
        // once the capture lands.
        isSpacePage || preview.imageURL != nil || ogImageURL != nil
    }

    /// The picture to draw: a Space page's own capture, or whatever the
    /// link's metadata pointed at.
    private var displayImage: UIImage? {
        isSpacePage ? spaceSnapshot : cachedImage
    }

    /// Whether this card points at the group's own Space, which is the page
    /// the Home is showing rather than somewhere out on the web.
    private var isSpacePage: Bool {
        guard let space = conversationSpaceURL, let url = preview.resolvedURL else { return false }
        return SpaceLink.matches(url, space: space)
    }

    /// The Space's host is a random-looking subdomain nobody can read, and it
    /// is the same string on every card from this group. When the page is the
    /// group's own, what is worth knowing instead is how fresh it is.
    private var showsLastUpdated: Bool {
        isSpacePage && sentAt != nil
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
                if let image = displayImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blendMode(.multiply)
                } else if expectsImage {
                    Image(systemName: "link")
                        .font(.largeTitle)
                        .foregroundStyle(.colorTextSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 100.0)
                } else {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(ImageAreaModifier(
                hasKnownRatio: isSpacePage || displayImage != nil || preview.imageAspectRatio != nil,
                aspectRatio: clampedAspectRatio
            ))
            .clipped()
            .background(.colorBackgroundMedia)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text(displayTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.colorTextPrimary)
                    .font(.callout.weight(.medium))
                    .truncationMode(.tail)
                Group {
                    if let sentAt, showsLastUpdated {
                        LastUpdatedLabel(date: sentAt)
                    } else {
                        Text(displaySubtitle)
                    }
                }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Link preview: \(displayTitle)")
        .accessibilityHint(isSpacePage ? "Opens this page in the group's space" : "Opens \(preview.displayHost)")
        .task {
            await fetchOpenGraphMetadata()
        }
        .task(id: spaceSnapshotIdentity) {
            await loadSpaceSnapshot()
        }
    }

    /// Re-captures when the page or the appearance changes, and not otherwise.
    private var spaceSnapshotIdentity: String? {
        guard isSpacePage, let url = preview.resolvedURL else { return nil }
        return url.absoluteString + (colorScheme == .dark ? "-dark" : "-light")
    }

    /// Draws the Space page itself rather than an image it declares.
    ///
    /// The cached capture is taken synchronously first so a card that has one
    /// draws it on its first layout, then the renderer is asked - which returns
    /// that same capture immediately and refreshes behind it if it has aged.
    private func loadSpaceSnapshot() async {
        guard isSpacePage, let url = preview.resolvedURL else { return }
        let appearance: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light

        if let cached = SpacePageSnapshotRenderer.shared.cachedSnapshot(for: url, appearance: appearance) {
            spaceSnapshot = cached
        }
        if let image = await SpacePageSnapshotRenderer.shared.snapshot(for: url, appearance: appearance) {
            spaceSnapshot = image
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

        if let metadata,
           preview.imageWidth == nil || preview.title == nil {
            let enriched = preview.enriched(
                title: metadata.title,
                imageURL: metadata.imageURL,
                siteName: metadata.siteName,
                imageWidth: metadata.imageWidth,
                imageHeight: metadata.imageHeight
            )
            if let messageId {
                await LinkPreviewWriter.shared?.updateLinkPreview(enriched, forMessageId: messageId)
            } else {
                TransientLinkPreviewCache.store(enriched)
            }
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

/// "Updated just now" / "Updated 5 minutes ago" for a link into the group's
/// own Space, kept honest while the card stays on screen.
///
/// Re-ticks on the same schedule as the transcript's own timestamps
/// (`RelativeDateLabel`) rather than on a fixed interval: a card read a second
/// after it arrived must not still claim "just now" ten minutes later.
private struct LastUpdatedLabel: View {
    let date: Date

    @State private var phrase: String

    init(date: Date) {
        self.date = date
        // Seeded here rather than filled in on appear. An empty first frame
        // measures a line shorter than the settled one, so the cell's height
        // changes after the collection view has already measured it - which is
        // the inconsistent self-sizing its feedback-loop debugger traps on.
        _phrase = State(initialValue: Self.text(for: date))
    }

    var body: some View {
        Text(phrase)
            .task(id: date) {
                phrase = Self.text(for: date)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.nextUpdateInterval(for: date)))
                    guard !Task.isCancelled else { break }
                    phrase = Self.text(for: date)
                }
            }
    }

    private static func text(for date: Date) -> String {
        "Updated \(date.relativeLong())"
    }

    private static func nextUpdateInterval(for date: Date) -> TimeInterval {
        let secondsAgo = abs(Date().timeIntervalSince(date))
        if secondsAgo < 60 {
            return 30.0
        } else if secondsAgo < 3600 {
            return 60.0
        } else {
            return 3600.0
        }
    }
}

/// In-memory enrichment for link previews with no backing database row
/// (extracted edge links on text messages persist nothing). Re-displays
/// start at the settled card size instead of replaying the
/// placeholder-then-resize jump on every scroll-by.
enum TransientLinkPreviewCache {
    private final class Entry: NSObject {
        let preview: LinkPreview

        init(_ preview: LinkPreview) {
            self.preview = preview
        }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Entry> = .init()

    static func enriched(_ preview: LinkPreview) -> LinkPreview {
        cache.object(forKey: preview.url as NSString)?.preview ?? preview
    }

    static func store(_ preview: LinkPreview) {
        cache.setObject(Entry(preview), forKey: preview.url as NSString)
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
#endif
