import ConvosCore
import SwiftUI

/// Cycles through mock thing items in the Things-tab empty state. Each
/// item renders a square preview from a real example HTML file via
/// [[HTMLThumbnailRenderer]] (the same pipeline actual thing cells use)
/// with a small label pill over the bottom edge, crossfading from one
/// item to the next.
struct EmptyStateMockThingCarousel: View {
    let mocks: [EmptyStateResolvedMockThing]

    @State private var index: Int = 0
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    private var currentMock: EmptyStateResolvedMockThing? {
        guard !mocks.isEmpty else { return nil }
        return mocks[index % mocks.count]
    }

    var body: some View {
        ZStack {
            if let mock = currentMock {
                EmptyStateMockThingCell(item: mock)
                    .id(mock.id)
                    .transition(.blurReplace)
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

/// Mock counterpart of [[ThingPreviewCell]]: the same square preview with
/// the 28pt continuous corner radius, loading its thumbnail from a local
/// example HTML file instead of a conversation attachment, with a label
/// pill ("Dinner suggestion" etc.) over the bottom-leading corner and the
/// mock source conversation's name captioned underneath (same style as
/// the mock conversation carousel's name caption).
struct EmptyStateMockThingCell: View {
    let item: EmptyStateResolvedMockThing

    @State private var renderedImage: UIImage?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .center, spacing: DesignConstants.Spacing.step2x) {
            preview
            conversationNameLabel
        }
    }

    private var preview: some View {
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
            .overlay(alignment: .bottom) {
                labelPill
            }
            .clipShape(RoundedRectangle(cornerRadius: Constant.cornerRadius, style: .continuous))
            .task(id: thumbnailTaskId) {
                await loadThumbnail()
            }
    }

    @ViewBuilder
    private var conversationNameLabel: some View {
        if let conversationName = item.conversationName, !conversationName.isEmpty {
            Text(conversationName)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Per the design spec: a bottom-centered pill, white at 60% over a
    /// backdrop blur, no border, with a small gap between the emoji and
    /// the label. Fixed dark text because the fill stays light in both
    /// appearances. Only rendered for things that carry a title; the
    /// others (streak tracker, countdown) label themselves in the artwork.
    @ViewBuilder
    private var labelPill: some View {
        if let title = item.title, !title.isEmpty {
            HStack(spacing: Constant.pillGap) {
                if let emoji = item.emoji, !emoji.isEmpty {
                    Text(emoji)
                }
                Text(title)
                    .foregroundStyle(.black)
            }
            .font(.footnote)
            .lineLimit(1)
            .padding(.horizontal, Constant.pillPadding)
            .frame(height: Constant.pillHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.6))
            }
            .padding(.bottom, Constant.pillBottomInset)
        }
    }

    /// Includes the color scheme so the `.task(id:)` re-fires and swaps in
    /// the matching appearance's render when the user toggles light/dark,
    /// mirroring [[ThingPreviewCell]].
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
        static let pillHeight: CGFloat = 29.0
        static let pillPadding: CGFloat = 7.3
        static let pillGap: CGFloat = 3.6
        static let pillBottomInset: CGFloat = 7.3
    }
}
