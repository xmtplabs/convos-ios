import ConvosCore
import ConvosLogging
import SwiftUI
import UIKit

/// Inline thumbnail used inside a message group for an agent-sent HTML
/// page. Renders as a 160x160 square with a 20pt corner radius and
/// leaves the sender avatar to the surrounding `MessagesGroupView` (no
/// header / no view affordance - the whole tile is tappable to open
/// the file via the standard message gesture).
struct HTMLAttachmentBubble: View {
    let attachment: HydratedAttachment
    let profile: Profile
    let reactions: [MessageReaction]
    var agentVerification: AgentVerification = .unverified
    var onTapAvatar: (() -> Void)?
    var onTapReactions: (() -> Void)?
    var cornerRadiusOverride: CGFloat?
    /// Namespace owned by the SwiftUI host (`MessagesView`) and threaded
    /// down through `MessagesViewController`'s cell config so the bubble
    /// can pair with the post-tap `AttachmentPreviewSheet`'s
    /// `.navigationTransition(.zoom(sourceID:in:))` for a matched-geometry
    /// transition. `nil` in contexts that don't present the sheet (e.g.
    /// reply parent thumbnails, context-menu snapshots).
    var transitionNamespace: Namespace.ID?

    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var renderedImage: UIImage?
    @State private var hasLoadFailed: Bool = false

    var body: some View {
        bubble
            .accessibilityIdentifier("html-attachment-bubble")
            .accessibilityLabel("HTML page from \(profile.displayName)")
            .onAppear(perform: seedFromMemoryCache)
            .task(id: AttachmentColorSchemeKey(key: attachment.key, scheme: colorScheme)) {
                await loadThumbnail()
            }
    }

    @ViewBuilder
    private var bubble: some View {
        let base = preview
            .frame(width: Constant.size, height: Constant.size)
            .background(Color.colorFillMinimal)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if !reactions.isEmpty {
                    let tap: () -> Void = {
                        onTapReactions?()
                    }
                    MediaContainerReax(reactions: reactions, onTap: tap)
                }
            }
        if let transitionNamespace {
            base.matchedTransitionSource(id: attachment.key, in: transitionNamespace)
        } else {
            base
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let renderedImage {
            Image(uiImage: renderedImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Constant.size, height: Constant.size, alignment: .top)
                .clipped()
        } else {
            ZStack {
                Color.clear
                if hasLoadFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
    }

    private var cornerRadius: CGFloat {
        cornerRadiusOverride ?? Constant.cornerRadius
    }

    /// Synchronous memory-cache read so an already-rendered tile shows its
    /// thumbnail on the first frame after the cell is reconfigured, rather
    /// than flashing the spinner until `loadThumbnail`'s async path runs.
    /// The hosting cell rebuilds this view (and resets `@State`) on every
    /// reuse, so without this seed every scroll back into view flickers.
    /// Mirrors the no-flicker pattern in `View.cachedImage(for:into:)`.
    private func seedFromMemoryCache() {
        guard renderedImage == nil else { return }
        if let cached = HTMLThumbnailRenderer.shared.cachedThumbnail(
            for: attachment.key,
            appearance: colorScheme.uiUserInterfaceStyle
        ) {
            renderedImage = cached
            hasLoadFailed = false
        }
    }

    private func loadThumbnail() async {
        let appearance = colorScheme.uiUserInterfaceStyle
        if let cached = HTMLThumbnailRenderer.shared.cachedThumbnail(
            for: attachment.key,
            appearance: appearance
        ) {
            renderedImage = cached
            hasLoadFailed = false
            await prewarmLiveContentIfPossible()
            return
        }
        // No in-memory thumbnail. Keep showing whatever we already have - a
        // thumbnail seeded on appear, or the other-appearance image during a
        // color-scheme swap - while we resolve the file and read disk or
        // re-render, so a shown tile never blanks back to a spinner.
        do {
            let fileURL = try await FileAttachmentLoader.loadFile(for: attachment)
            let image = await HTMLThumbnailRenderer.shared.thumbnail(
                for: attachment.key,
                fileURL: fileURL,
                appearance: appearance
            )
            if let image {
                renderedImage = image
                hasLoadFailed = false
            } else if renderedImage == nil {
                // Only surface the warning when there's nothing to show; a
                // transient render miss shouldn't replace a good thumbnail
                // (the bytes are usually still on disk for the next pass).
                hasLoadFailed = true
            }
            HTMLContentPrewarmer.shared.prewarm(attachmentKey: attachment.key, fileURL: fileURL)
        } catch {
            Log.error("Failed to load HTML attachment thumbnail: \(error)")
            if renderedImage == nil {
                hasLoadFailed = true
            }
        }
    }

    /// Cached-thumbnail path doesn't go through `FileAttachmentLoader`, so
    /// resolve the file URL here so the prewarmer can load the same file
    /// into a live WebView. Cheap when the file is already on disk; the
    /// loader caches its result.
    private func prewarmLiveContentIfPossible() async {
        do {
            let fileURL = try await FileAttachmentLoader.loadFile(for: attachment)
            HTMLContentPrewarmer.shared.prewarm(attachmentKey: attachment.key, fileURL: fileURL)
        } catch {
            Log.error("Failed to resolve fileURL for HTML prewarm: \(error.localizedDescription)")
        }
    }

    private enum Constant {
        static let size: CGFloat = 160.0
        static let cornerRadius: CGFloat = 20.0
    }
}

/// Composite key so `.task(id:)` re-fires when either the attachment or the
/// SwiftUI color scheme changes — the renderer keys its cache on appearance
/// too, so toggling dark mode swaps to a freshly-rendered thumbnail.
struct AttachmentColorSchemeKey: Hashable {
    let key: String
    let scheme: ColorScheme
}

extension ColorScheme {
    var uiUserInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .dark: return .dark
        case .light: return .light
        @unknown default: return .light
        }
    }
}
