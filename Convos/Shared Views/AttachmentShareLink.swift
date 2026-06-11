import ConvosCore
import ConvosLogging
import SwiftUI
import UIKit

/// Share button for HTML and Markdown attachments, used by both the
/// in-conversation attachment preview and the Stuff detail screen so the
/// share payload stays identical everywhere. HTML shares the full-page
/// rendered image only (the share sheet preview stays the square tile);
/// Markdown shares the underlying file, adding the rendered thumbnail
/// image once it resolves.
struct AttachmentShareLink: View {
    let attachment: HydratedAttachment
    let fileURL: URL

    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var resolvedHTMLTitle: String?
    @State private var sharedImage: UIImage?
    @State private var sharedImageURL: URL?

    static func canShare(_ attachment: HydratedAttachment) -> Bool {
        attachment.isHTMLFile || attachment.isMarkdownFile
    }

    var body: some View {
        shareLink
            .accessibilityLabel("Share")
            .task(id: attachment.key) {
                await resolveTitleIfNeeded()
                await resolveShareImageIfNeeded()
            }
    }

    @ViewBuilder
    private var shareLink: some View {
        let title: String = resolvedHTMLTitle ?? attachment.filename ?? "Attachment"
        if let url = sharedImageURL, let image = sharedImage {
            let previewImage: Image = Image(uiImage: image)
            let items: [URL] = attachment.isHTMLFile ? [url] : [fileURL, url]
            ShareLink(items: items, preview: { (_: URL) in
                SharePreview(title, image: previewImage)
            }, label: {
                Image(systemName: "square.and.arrow.up")
            })
        } else if attachment.isHTMLFile {
            // HTML shares only the rendered image, so there is nothing to
            // share until the full-page render lands.
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.secondary)
        } else {
            ShareLink(items: [fileURL], preview: { (_: URL) in
                SharePreview(title)
            }, label: {
                Image(systemName: "square.and.arrow.up")
            })
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
        if attachment.isHTMLFile {
            await resolveHTMLShareContent()
            return
        }
        guard attachment.isMarkdownFile, let image = await resolveMarkdownShareImage() else { return }
        let url: URL? = await writeSharePNG(image: image, basename: shareImageBasename())
        sharedImage = image
        sharedImageURL = url
    }

    private func resolveHTMLShareContent() async {
        let appearance = colorScheme.uiUserInterfaceStyle
        let thumbnail: UIImage? = await resolveHTMLThumbnail(appearance: appearance)
        // Share the full-page render when available; the square tile stays
        // the share sheet preview so it reads as a card, not a tall sliver.
        // The PNG is rendered once and disk-cached, so reopening the
        // detail view arms the share button instantly.
        let fullPageURL: URL? = await HTMLThumbnailRenderer.shared.fullPagePNGURL(
            for: attachment.key,
            fileURL: fileURL,
            appearance: appearance,
            basename: shareImageBasename()
        )
        guard let thumbnail else { return }
        if let fullPageURL {
            sharedImage = thumbnail
            sharedImageURL = fullPageURL
            return
        }
        // Full-page render failed; fall back to sharing the tile image.
        let fallbackURL: URL? = await writeSharePNG(image: thumbnail, basename: shareImageBasename())
        sharedImage = thumbnail
        sharedImageURL = fallbackURL
    }

    private func resolveHTMLThumbnail(appearance: UIUserInterfaceStyle) async -> UIImage? {
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
            return cached.image
        }
        guard let result = await FileThumbnailRenderer.shared.thumbnail(for: attachment.key, fileURL: fileURL),
              result.isContentThumbnail else {
            return nil
        }
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
        let url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("\(basename).png")
        // Full-page renders are large bitmaps; encode and write off the main
        // actor so the share button does not stall the UI.
        let written: Bool = await Task.detached(priority: .utility) {
            guard let pngData = image.pngData() else {
                Log.error("AttachmentShareLink: failed to encode share image PNG")
                return false
            }
            do {
                try pngData.write(to: url, options: .atomic)
                return true
            } catch {
                Log.error("AttachmentShareLink: failed to write share PNG: \(error)")
                return false
            }
        }.value
        return written ? url : nil
    }
}
