#if canImport(UIKit)
import ConvosCore
import ConvosLogging
import SwiftUI
import UIKit

/// The resolved share content for an HTML or Markdown attachment, shared by
/// `AttachmentShareLink` and the message context menu's Share action so the
/// payload stays identical everywhere. HTML shares the full-page rendered
/// image only (the share sheet preview stays the square tile); Markdown
/// shares the underlying file, adding the rendered thumbnail image once it
/// resolves.
struct AttachmentSharePayload {
    let items: [URL]
    let title: String
    let previewImage: UIImage?

    /// Resolves the share payload, rendering and disk-caching share images
    /// as needed. Returns nil when there is nothing shareable yet (e.g. the
    /// HTML full-page render and tile thumbnail both failed).
    @MainActor
    static func resolve(
        attachment: HydratedAttachment,
        fileURL: URL,
        appearance: UIUserInterfaceStyle,
        fallbackTitle: String?
    ) async -> AttachmentSharePayload? {
        if attachment.isHTMLFile {
            return await resolveHTML(
                attachment: attachment,
                fileURL: fileURL,
                appearance: appearance,
                fallbackTitle: fallbackTitle
            )
        }
        if attachment.isMarkdownFile {
            return await resolveMarkdown(
                attachment: attachment,
                fileURL: fileURL,
                fallbackTitle: fallbackTitle
            )
        }
        return nil
    }

    @MainActor
    private static func resolveHTML(
        attachment: HydratedAttachment,
        fileURL: URL,
        appearance: UIUserInterfaceStyle,
        fallbackTitle: String?
    ) async -> AttachmentSharePayload? {
        // The user-facing share name. For HTML artifacts the raw filename is
        // never shown - the artifact's title, then the agent's name, stand in.
        let resolvedTitle: String?
        if let cached = HTMLPageMetadata.shared.cachedTitle(for: attachment.key) {
            resolvedTitle = cached
        } else {
            resolvedTitle = await HTMLPageMetadata.shared.title(for: attachment.key, fileURL: fileURL)
        }
        let title: String = resolvedTitle ?? fallbackTitle ?? "Attachment"
        let basename: String = sanitizeFilename(
            resolvedTitle ?? fallbackTitle ?? String(attachment.key.prefix(32))
        )

        let thumbnail: UIImage? = await resolveHTMLThumbnail(
            attachment: attachment,
            fileURL: fileURL,
            appearance: appearance
        )
        // Share the full-page render when available; the square tile stays
        // the share sheet preview so it reads as a card, not a tall sliver.
        // The PNG is rendered once and disk-cached, so re-sharing arms
        // instantly.
        let fullPageURL: URL? = await HTMLThumbnailRenderer.shared.fullPagePNGURL(
            for: attachment.key,
            fileURL: fileURL,
            appearance: appearance,
            basename: basename
        )
        if let fullPageURL {
            // Arm even when the tile thumbnail failed - the share sheet
            // then shows a title-only preview instead of staying dimmed.
            return AttachmentSharePayload(items: [fullPageURL], title: title, previewImage: thumbnail)
        }
        // Full-page render failed; fall back to sharing the tile image.
        guard let thumbnail,
              let fallbackURL = await writeSharePNG(image: thumbnail, basename: basename, attachmentKey: attachment.key) else {
            return nil
        }
        return AttachmentSharePayload(items: [fallbackURL], title: title, previewImage: thumbnail)
    }

    @MainActor
    private static func resolveMarkdown(
        attachment: HydratedAttachment,
        fileURL: URL,
        fallbackTitle: String?
    ) async -> AttachmentSharePayload? {
        guard let image = await resolveMarkdownShareImage(attachment: attachment, fileURL: fileURL) else {
            return nil
        }
        // The basename is the filename recipients see on the delivered
        // image, so it follows the share title rather than the raw
        // attachment filename.
        let raw: String
        if let filename = attachment.filename, !filename.isEmpty {
            raw = (filename as NSString).deletingPathExtension
        } else {
            raw = String(attachment.key.prefix(32))
        }
        guard let url = await writeSharePNG(image: image, basename: sanitizeFilename(raw), attachmentKey: attachment.key) else {
            return nil
        }
        let title: String = attachment.filename ?? fallbackTitle ?? "Attachment"
        return AttachmentSharePayload(items: [fileURL, url], title: title, previewImage: image)
    }

    @MainActor
    private static func resolveHTMLThumbnail(
        attachment: HydratedAttachment,
        fileURL: URL,
        appearance: UIUserInterfaceStyle
    ) async -> UIImage? {
        if let cached = HTMLThumbnailRenderer.shared.cachedThumbnail(for: attachment.key, appearance: appearance) {
            return cached
        }
        return await HTMLThumbnailRenderer.shared.thumbnail(
            for: attachment.key,
            fileURL: fileURL,
            appearance: appearance
        )
    }

    @MainActor
    private static func resolveMarkdownShareImage(
        attachment: HydratedAttachment,
        fileURL: URL
    ) async -> UIImage? {
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

    private static func sanitizeFilename(_ raw: String) -> String {
        let allowed: CharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        var output: String = ""
        for scalar in raw.unicodeScalars {
            output.append(allowed.contains(scalar) ? Character(scalar) : "_")
        }
        let trimmed: String = output.trimmingCharacters(in: .whitespaces)
        let fallback: String = trimmed.isEmpty ? "image" : trimmed
        return String(fallback.prefix(64))
    }

    private static func writeSharePNG(image: UIImage, basename: String, attachmentKey: String) async -> URL? {
        // Namespace by attachment key so same-named attachments cannot
        // overwrite each other's armed share payload.
        let url: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-" + HTMLThumbnailRenderer.stableKeyComponent(for: attachmentKey), isDirectory: true)
            .appendingPathComponent("\(basename).png")
        // Full-page renders are large bitmaps; encode and write off the main
        // actor so the share button does not stall the UI.
        let written: Bool = await Task.detached(priority: .utility) {
            guard let pngData = image.pngData() else {
                Log.error("AttachmentSharePayload: failed to encode share image PNG")
                return false
            }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try pngData.write(to: url, options: .atomic)
                return true
            } catch {
                Log.error("AttachmentSharePayload: failed to write share PNG: \(error)")
                return false
            }
        }.value
        return written ? url : nil
    }
}

/// Share button for HTML and Markdown attachments, used by both the
/// in-conversation attachment preview and the Stuff detail screen. The
/// share content comes from `AttachmentSharePayload` so it matches the
/// message context menu's Share action.
public struct AttachmentShareLink: View {
    let attachment: HydratedAttachment
    let fileURL: URL
    /// Shown (and used as the shared file's name) when the artifact has no
    /// resolvable HTML title - pass the creating agent's display name.
    var fallbackTitle: String?

    public init(attachment: HydratedAttachment, fileURL: URL, fallbackTitle: String? = nil) {
        self.attachment = attachment
        self.fileURL = fileURL
        self.fallbackTitle = fallbackTitle
    }

    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var payload: AttachmentSharePayload?

    public static func canShare(_ attachment: HydratedAttachment) -> Bool {
        attachment.isHTMLFile || attachment.isMarkdownFile
    }

    public var body: some View {
        // The id includes the appearance so a light/dark switch re-renders
        // the share payload instead of leaving the previous scheme armed.
        let appearanceSuffix: String = colorScheme == .dark ? "dark" : "light"
        shareLink
            .accessibilityLabel("Share")
            .task(id: "\(attachment.key)-\(appearanceSuffix)") {
                payload = nil
                payload = await AttachmentSharePayload.resolve(
                    attachment: attachment,
                    fileURL: fileURL,
                    appearance: colorScheme.uiUserInterfaceStyle,
                    fallbackTitle: fallbackTitle
                )
            }
    }

    @ViewBuilder
    private var shareLink: some View {
        if let payload {
            if let image = payload.previewImage {
                let previewImage: Image = Image(uiImage: image)
                ShareLink(items: payload.items, preview: { (_: URL) in
                    SharePreview(payload.title, image: previewImage)
                }, label: {
                    Image(systemName: "square.and.arrow.up")
                })
            } else {
                ShareLink(items: payload.items, preview: { (_: URL) in
                    SharePreview(payload.title)
                }, label: {
                    Image(systemName: "square.and.arrow.up")
                })
            }
        } else if attachment.isHTMLFile {
            // HTML shares only the rendered image, so there is nothing to
            // share until the full-page render lands.
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.secondary)
        } else {
            ShareLink(items: [fileURL], preview: { (_: URL) in
                SharePreview(attachment.filename ?? fallbackTitle ?? "Attachment")
            }, label: {
                Image(systemName: "square.and.arrow.up")
            })
        }
    }
}
#endif
