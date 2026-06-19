import ConvosCore
import SwiftUI

/// One square cell in the Things tab's 2-column grid. Renders a single
/// HTML attachment from the conversation as a square preview (28pt corner
/// radius, `.colorFillTertiary` placeholder while loading) with the
/// thing's title under it. The label prefers the HTML document's
/// `<title>` (resolved via `HTMLPageMetadata`, matching the in-conversation
/// files list), falling back to the filename, then the conversation name.
struct ThingPreviewCell: View {
    let item: ThingOverviewItem

    @State private var renderedImage: UIImage?
    @State private var resolvedTitle: String?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    /// Label under the cell. Precedence mirrors `AgentFilesLinksView.FileRow`:
    /// resolved HTML `<title>` -> filename (extension stripped) -> the
    /// conversation's display name.
    private var thingName: String {
        if let resolvedTitle, !resolvedTitle.isEmpty {
            return resolvedTitle
        }
        if let filename = item.filename, !filename.isEmpty {
            return (filename as NSString).deletingPathExtension
        }
        return item.conversation.computedDisplayName
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            preview
            // Unread dot intentionally hidden for now — tapping a Things
            // cell pushes the file detail view, which doesn't mark the
            // underlying conversation as read. Re-enable once the tap
            // either marks-as-read or routes through the messages list.
            Text(thingName)
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
    }

    private var preview: some View {
        Color.colorFillTertiary
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let renderedImage {
                    Image(uiImage: renderedImage)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Constant.cornerRadius, style: .continuous))
            .task(id: thumbnailTaskId) {
                await loadThumbnail()
            }
    }

    /// Compose the attachment key with the current `colorScheme` so the
    /// `.task(id:)` re-fires when the user toggles light/dark mode.
    /// Without `colorScheme` in the id, the thumbnail rendered for the
    /// previous appearance lingers until the conversation's attachment
    /// key changes.
    private var thumbnailTaskId: String {
        "\(item.attachmentKey)-\(colorScheme == .dark ? "dark" : "light")"
    }

    @MainActor
    private func loadThumbnail() async {
        let appearance = colorScheme.uiUserInterfaceStyle
        if let cachedTitle = HTMLPageMetadata.shared.cachedTitle(for: item.attachmentKey) {
            resolvedTitle = cachedTitle
        }
        if let cached = HTMLThumbnailRenderer.shared.cachedThumbnail(
            for: item.attachmentKey,
            appearance: appearance
        ) {
            withAnimation(.smooth(duration: 0.2)) {
                renderedImage = cached
            }
        }
        guard renderedImage == nil || resolvedTitle == nil else { return }
        do {
            let fileURL = try await FileAttachmentLoader.loadFile(for: item.hydratedAttachment)
            if renderedImage == nil {
                let image = await HTMLThumbnailRenderer.shared.thumbnail(
                    for: item.attachmentKey,
                    fileURL: fileURL,
                    appearance: appearance
                )
                withAnimation(.smooth(duration: 0.2)) {
                    renderedImage = image
                }
            }
            if resolvedTitle == nil {
                resolvedTitle = await HTMLPageMetadata.shared.title(
                    for: item.attachmentKey,
                    fileURL: fileURL
                )
            }
        } catch {
            Log.error("ThingPreviewCell: failed to load thumbnail for \(item.conversation.id): \(error)")
        }
    }

    private enum Constant {
        static let cornerRadius: CGFloat = 28.0
        static let unreadDotSize: CGFloat = 8.0
    }
}
