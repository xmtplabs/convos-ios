import ConvosComposer
import ConvosCore
import SwiftUI

/// Staged (not-yet-sent) file attachment content for the composer's
/// attachment strip. Injected into the package-hosted `MessagesInputView`
/// through its `fileAttachmentPreview` slot; the package wraps this content
/// with the shared poof animation and remove button.
struct ComposerFileAttachmentPreview: View {
    let file: PendingFileAttachment

    private let attachmentPreviewSize: CGFloat = 80.0

    var body: some View {
        if file.isHTMLFile {
            ComposerHTMLThumbnail(
                fileURL: file.url,
                cacheKey: "composer-html-\(file.id.uuidString)"
            )
            .frame(width: attachmentPreviewSize, height: attachmentPreviewSize)
            .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
            .accessibilityLabel("HTML attachment preview")
            .accessibilityIdentifier("html-attachment-preview")
        } else {
            FileAttachmentRow(
                filename: file.filename,
                mimeType: file.mimeType,
                fileSize: file.fileSize
            )
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .frame(maxWidth: 240.0)
            .background(.colorFillSubtle)
            .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("file-attachment-preview")
        }
    }
}

/// Square HTML thumbnail for a staged (not-yet-sent) file attachment in the
/// composer. Renders the same `HTMLThumbnailRenderer` preview the in-chat
/// `HTMLAttachmentBubble` uses, loaded from the local file URL, so a staged
/// HTML file reads as a small page tile instead of the generic filename +
/// "HTML" file chip. Keyed on a composer-local key (the staged attachment id),
/// distinct from the content-addressed key the sent attachment later uses.
private struct ComposerHTMLThumbnail: View {
    let fileURL: URL
    let cacheKey: String

    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var renderedImage: UIImage?
    @State private var hasLoadFailed: Bool = false

    var body: some View {
        Group {
            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.colorFillSubtle
                    if hasLoadFailed {
                        Image(systemName: "globe")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .onAppear(perform: seedFromMemoryCache)
        .task(id: AttachmentColorSchemeKey(key: cacheKey, scheme: colorScheme)) {
            await loadThumbnail()
        }
    }

    private func seedFromMemoryCache() {
        guard renderedImage == nil else { return }
        if let cached = HTMLThumbnailRenderer.shared.cachedThumbnail(
            for: cacheKey,
            appearance: colorScheme.uiUserInterfaceStyle
        ) {
            renderedImage = cached
            hasLoadFailed = false
        }
    }

    private func loadThumbnail() async {
        let appearance = colorScheme.uiUserInterfaceStyle
        if let cached = HTMLThumbnailRenderer.shared.cachedThumbnail(for: cacheKey, appearance: appearance) {
            renderedImage = cached
            hasLoadFailed = false
            return
        }
        let image = await HTMLThumbnailRenderer.shared.thumbnail(
            for: cacheKey,
            fileURL: fileURL,
            appearance: appearance
        )
        if let image {
            renderedImage = image
            hasLoadFailed = false
        } else if renderedImage == nil {
            hasLoadFailed = true
        }
    }
}
