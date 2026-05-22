import ConvosCore
import SwiftUI

/// One square cell in the Stuff tab's 2-column grid. Renders the most
/// recent HTML attachment from the conversation as a square preview
/// (28pt corner radius, `.colorFillTertiary` placeholder while loading)
/// with the conversation's display name + unread dot under it.
struct StuffPreviewCell: View {
    let item: StuffOverviewItem

    @State private var renderedImage: UIImage?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    private var conversationName: String {
        item.conversation.computedDisplayName
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            preview
            // Unread dot intentionally hidden for now — tapping a Stuff
            // cell pushes the file detail view, which doesn't mark the
            // underlying conversation as read. Re-enable once the tap
            // either marks-as-read or routes through the messages list.
            Text(conversationName)
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
            .task(id: item.attachmentKey) {
                await loadThumbnail()
            }
    }

    private func loadThumbnail() async {
        let appearance = colorScheme.uiUserInterfaceStyle
        if let cached = HTMLThumbnailRenderer.shared.cachedThumbnail(
            for: item.attachmentKey,
            appearance: appearance
        ) {
            withAnimation(.smooth(duration: 0.2)) {
                renderedImage = cached
            }
            return
        }
        do {
            let fileURL = try await FileAttachmentLoader.loadFile(for: item.hydratedAttachment)
            let image = await HTMLThumbnailRenderer.shared.thumbnail(
                for: item.attachmentKey,
                fileURL: fileURL,
                appearance: appearance
            )
            await MainActor.run {
                withAnimation(.smooth(duration: 0.2)) {
                    renderedImage = image
                }
            }
        } catch {
            Log.error("StuffPreviewCell: failed to load thumbnail for \(item.conversation.id): \(error)")
        }
    }

    private enum Constant {
        static let cornerRadius: CGFloat = 28.0
        static let unreadDotSize: CGFloat = 8.0
    }
}
