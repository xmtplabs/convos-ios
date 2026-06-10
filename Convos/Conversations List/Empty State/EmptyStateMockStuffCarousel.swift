import ConvosCore
import SwiftUI

/// Cycles through mock stuff items in the Stuff-tab empty state. Each
/// item renders a square preview from a real example HTML file via
/// [[HTMLThumbnailRenderer]] (the same pipeline actual stuff cells use)
/// with a small label pill over the bottom edge, crossfading from one
/// item to the next.
struct EmptyStateMockStuffCarousel: View {
    let mocks: [EmptyStateResolvedMockStuff]

    @State private var index: Int = 0
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    private var currentMock: EmptyStateResolvedMockStuff? {
        guard !mocks.isEmpty else { return nil }
        return mocks[index % mocks.count]
    }

    var body: some View {
        ZStack {
            if let mock = currentMock {
                EmptyStateMockStuffCell(item: mock)
                    .id(mock.id)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .task(id: mocks) {
            await cycle()
        }
    }

    /// Pre-renders every mock's thumbnail before starting the rotation so
    /// each crossfade lands on a painted preview instead of a placeholder.
    private func cycle() async {
        guard !mocks.isEmpty else { return }
        index = 0
        let appearance = colorScheme.uiUserInterfaceStyle
        for mock in mocks where !Task.isCancelled {
            _ = await HTMLThumbnailRenderer.shared.thumbnail(
                for: mock.thumbnailKey,
                fileURL: mock.fileURL,
                appearance: appearance
            )
        }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Constant.itemDuration))
                withAnimation(.smooth(duration: 0.35)) {
                    index += 1
                }
            } catch {
                return
            }
        }
    }

    private enum Constant {
        static let itemDuration: TimeInterval = 3.2
    }
}

/// Mock counterpart of [[StuffPreviewCell]]: the same square preview with
/// the 28pt continuous corner radius, loading its thumbnail from a local
/// example HTML file instead of a conversation attachment, with a label
/// pill ("Dinner suggestion" etc.) over the bottom-leading corner.
struct EmptyStateMockStuffCell: View {
    let item: EmptyStateResolvedMockStuff

    @State private var renderedImage: UIImage?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    var body: some View {
        Color.colorFillTertiary
            .frame(width: Constant.previewSize, height: Constant.previewSize)
            .overlay {
                if let renderedImage {
                    Image(uiImage: renderedImage)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                labelPill
            }
            .clipShape(RoundedRectangle(cornerRadius: Constant.cornerRadius, style: .continuous))
            .task(id: thumbnailTaskId) {
                await loadThumbnail()
            }
    }

    private var labelText: String {
        if let emoji = item.emoji, !emoji.isEmpty {
            return "\(emoji) \(item.title)"
        }
        return item.title
    }

    private var labelPill: some View {
        Text(labelText)
            .font(.caption2)
            .foregroundStyle(.colorTextPrimary)
            .lineLimit(1)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .background(Color.colorBackgroundRaised)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .inset(by: 0.5)
                    .stroke(Color.colorBorderSubtle, lineWidth: 1)
            )
            .padding(DesignConstants.Spacing.step2x)
    }

    /// Includes the color scheme so the `.task(id:)` re-fires and swaps in
    /// the matching appearance's render when the user toggles light/dark,
    /// mirroring [[StuffPreviewCell]].
    private var thumbnailTaskId: String {
        "\(item.thumbnailKey)-\(colorScheme == .dark ? "dark" : "light")"
    }

    private func loadThumbnail() async {
        let appearance = colorScheme.uiUserInterfaceStyle
        if let cached = HTMLThumbnailRenderer.shared.cachedThumbnail(
            for: item.thumbnailKey,
            appearance: appearance
        ) {
            renderedImage = cached
            return
        }
        let image = await HTMLThumbnailRenderer.shared.thumbnail(
            for: item.thumbnailKey,
            fileURL: item.fileURL,
            appearance: appearance
        )
        withAnimation(.smooth(duration: 0.2)) {
            renderedImage = image
        }
    }

    private enum Constant {
        static let previewSize: CGFloat = 160.0
        static let cornerRadius: CGFloat = 28.0
    }
}
