import ConvosCore
import ConvosLogging
import SwiftUI
import UIKit

/// The resolved share content for an HTML or Markdown attachment, shared by
/// `AttachmentShareLink` and the message context menu's Share action so the
/// payload stays identical everywhere. HTML shares the underlying `.html`
/// file (copied to a title-named temp file so the raw on-disk filename is
/// never exposed); the rendered tile image rides along only as the share
/// sheet preview thumbnail, never as a second shared file. Markdown shares
/// the underlying file, adding the rendered thumbnail image once it resolves.
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
        // Share the actual `.html` file. Copy it to a title-named temp file so
        // recipients never see the raw on-disk filename, then hand that single
        // file over as the shared item. The rendered tile rides along only as
        // the share sheet preview thumbnail (never a second shared file), so
        // sharing arms as soon as the HTML exists - no wait on the slow
        // full-page render.
        guard let htmlURL = await writeShareHTML(fileURL: fileURL, basename: basename, attachmentKey: attachment.key) else {
            return nil
        }
        return AttachmentSharePayload(items: [htmlURL], title: title, previewImage: thumbnail)
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

    static func sanitizeFilename(_ raw: String) -> String {
        let allowed: CharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        var output: String = ""
        for scalar in raw.unicodeScalars {
            output.append(allowed.contains(scalar) ? Character(scalar) : "_")
        }
        // Trim whitespace plus any leading or trailing dots and underscores so a
        // title like ".secret" cannot produce a hidden file (".secret.html") or
        // a trailing-dot name that some filesystems mangle. Cap, then trim once
        // more in case the cap re-introduced a trailing dot.
        let strippable: CharacterSet = CharacterSet(charactersIn: "._").union(.whitespaces)
        let capped: String = String(output.trimmingCharacters(in: strippable).prefix(64))
        let cleaned: String = capped.trimmingCharacters(in: strippable)
        return cleaned.isEmpty ? "attachment" : cleaned
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

    /// Arms the immediate (pre-resolve) HTML share with a correctly
    /// `.html`-extensioned copy. The raw cached file may carry a missing or
    /// non-html on-disk extension (when `isHTMLFile` is MIME-only), so sharing
    /// it directly would deliver a file the recipient's OS opens as plain
    /// text. This reuses the same copy/extension-forcing as the resolved
    /// payload, using the fallback title (or the attachment key) as the
    /// basename. The copy is fast (no render), so sharing still arms as soon
    /// as the HTML exists.
    @MainActor
    static func immediateHTMLShareURL(
        attachment: HydratedAttachment,
        fileURL: URL,
        fallbackTitle: String?
    ) async -> URL? {
        // Prefer the already-cached page title so the immediate-arm filename
        // matches what the resolved payload would use; only when no title has
        // resolved yet do we fall back to the supplied title, then the key
        // prefix. The cached lookup is synchronous (no render), so sharing
        // still arms as soon as the HTML exists.
        let cachedTitle: String? = HTMLPageMetadata.shared.cachedTitle(for: attachment.key)
        let basename: String = sanitizeFilename(cachedTitle ?? fallbackTitle ?? String(attachment.key.prefix(32)))
        return await writeShareHTML(fileURL: fileURL, basename: basename, attachmentKey: attachment.key)
    }

    /// Copies the cached `.html` attachment to a title-named temp file so the
    /// shared item carries the artifact's name, not the raw on-disk filename.
    /// Recipients receive only this HTML file; the rendered image is preview
    /// metadata, never a shared item.
    private static func writeShareHTML(fileURL: URL, basename: String, attachmentKey: String) async -> URL? {
        // `isHTMLFile` can be true from the MIME type alone, so the cached
        // file's on-disk extension may be missing or non-html (e.g.
        // `report.txt`). Force `html` for the shared copy unless the existing
        // extension is already a valid HTML one, so recipients never get an
        // HTML payload that opens as plain text.
        let htmlExtensions: Set<String> = ["html", "htm"]
        let rawExtension: String = fileURL.pathExtension.lowercased()
        let ext: String = htmlExtensions.contains(rawExtension) ? rawExtension : "html"
        // Namespace by attachment key so same-named attachments cannot
        // overwrite each other's armed share payload.
        let url: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-" + HTMLThumbnailRenderer.stableKeyComponent(for: attachmentKey), isDirectory: true)
            .appendingPathComponent("\(basename).\(ext)")
        let written: Bool = await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: fileURL, to: url)
                return true
            } catch {
                Log.error("AttachmentSharePayload: failed to copy share HTML: \(error)")
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
struct AttachmentShareLink: View {
    let attachment: HydratedAttachment
    let fileURL: URL
    /// Shown (and used as the shared file's name) when the artifact has no
    /// resolvable HTML title - pass the creating agent's display name.
    var fallbackTitle: String?

    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var payload: AttachmentSharePayload?
    /// A correctly `.html`-extensioned copy of the raw file, armed before the
    /// slow render so the immediate-share fallback never hands over a
    /// wrong-extension file.
    @State private var immediateURL: URL?

    static func canShare(_ attachment: HydratedAttachment) -> Bool {
        attachment.isHTMLFile || attachment.isMarkdownFile
    }

    var body: some View {
        // The id includes the appearance so a light/dark switch re-renders
        // the share payload instead of leaving the previous scheme armed.
        let appearanceSuffix: String = colorScheme == .dark ? "dark" : "light"
        shareLink
            .accessibilityLabel("Share")
            .task(id: "\(attachment.key)-\(appearanceSuffix)") {
                payload = nil
                immediateURL = nil
                if attachment.isHTMLFile {
                    immediateURL = await AttachmentSharePayload.immediateHTMLShareURL(
                        attachment: attachment,
                        fileURL: fileURL,
                        fallbackTitle: fallbackTitle
                    )
                }
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
            // The HTML file already exists, so arm sharing immediately rather
            // than dimming while the preview thumbnail and title-named copy
            // resolve. Prefer the correctly `.html`-extensioned copy; fall back
            // to the raw file only until that fast copy lands, so the share is
            // never unavailable. The richer payload (title-named file + preview
            // image) swaps in once `resolve` finishes.
            let immediateItem: URL = immediateURL ?? fileURL
            ShareLink(item: immediateItem, preview: SharePreview(fallbackTitle ?? "Attachment")) {
                Image(systemName: "square.and.arrow.up")
            }
        } else {
            ShareLink(items: [fileURL], preview: { (_: URL) in
                SharePreview(attachment.filename ?? fallbackTitle ?? "Attachment")
            }, label: {
                Image(systemName: "square.and.arrow.up")
            })
        }
    }
}
