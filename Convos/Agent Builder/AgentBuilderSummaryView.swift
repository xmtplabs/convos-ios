import AVFoundation
import ConvosCore
import SwiftUI

/// The "summary card" cell shown where the user tapped Make. Reproduces the
/// AgentDraftComposer's rounded-rect liquid-glass styling (no bottom buttons, no
/// Make button) and the same attachment chips minus their X buttons. The footer
/// reads "You created an agent" / "<name> created an agent" in the group-update
/// text style.
///
/// The content is reconstructed by `MessagesListProcessor` from the build's own
/// messages (the prompt + attachment bundle every member receives), so the card
/// is visible to all members and sits in chronological order -- it is no longer
/// pinned to the top from a creator-only local summary.
struct AgentBuilderSummaryView: View {
    let content: AgentBuilderCardContent
    /// Namespace owned by `AgentBuilderView`. When non-nil the card pairs with
    /// the composer's glass rect via `glassEffectID +
    /// glassEffectTransition(.matchedGeometry)`, producing the morph on Make.
    /// Nil for recipients and the "returning later" case where the card simply
    /// renders in-place without an entry animation.
    var transitionNamespace: Namespace.ID?

    private var footerText: String {
        if content.creatorIsCurrentUser || content.creatorDisplayName.isEmpty {
            return "You created an agent"
        }
        return "\(content.creatorDisplayName) created an agent"
    }

    private var hasChips: Bool {
        !content.attachments.isEmpty || !content.connectionIdentifiers.isEmpty
    }

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            // `GlassEffectContainer` gives iOS a stable scope to coordinate
            // the card's backdrop-sampling pipeline. Standalone `.glassEffect`
            // inside a `UIHostingConfiguration` cell renders as opaque grey
            // on first mount because the cell is typically laid out off-screen
            // before being scrolled into view — the sampling layer has no
            // backdrop until the cell attaches to the window. The container
            // also scopes the matched-geometry transition cleanly to the
            // morph from the composer.
            GlassEffectContainer {
                card
            }
            Text(footerText)
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var card: some View {
        if let transitionNamespace {
            cardContent
                .glassEffectID(AgentBuilderTransition.glassEffectId, in: transitionNamespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            if !content.prompt.isEmpty {
                Text(content.prompt)
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if hasChips {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignConstants.Spacing.step2x) {
                        ForEach(content.attachments, id: \.key) { attachment in
                            chipView(for: attachment)
                        }
                        ForEach(content.connectionIdentifiers, id: \.self) { identifier in
                            connectionChip(identifier: identifier)
                        }
                    }
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                }
                .scrollClipDisabled()
                .padding(.horizontal, -DesignConstants.Spacing.step4x)
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.colorBackgroundRaised, in: .rect(cornerRadius: 24))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        .clipShape(.rect(cornerRadius: 24))
    }

    @ViewBuilder
    private func chipView(for attachment: HydratedAttachment) -> some View {
        switch attachment.mediaType {
        case .image:
            photoVideoChip(attachment: attachment, isVideo: false)
        case .video:
            photoVideoChip(attachment: attachment, isVideo: true)
        case .audio:
            voiceMemoChip(duration: attachment.duration ?? 0, levels: attachment.waveformLevels ?? [])
        case .file, .unknown:
            fileChip(filename: attachment.filename ?? "File")
        }
    }

    @ViewBuilder
    private func photoVideoChip(attachment: HydratedAttachment, isVideo: Bool) -> some View {
        AgentBuilderChipThumbnail(
            attachmentKey: attachment.key,
            thumbnailData: attachment.thumbnailData
        )
        .frame(width: chipSize, height: chipSize)
        .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
        .overlay(alignment: .bottomLeading) {
            if isVideo {
                Image(systemName: "video.fill")
                    .font(.system(size: 16.0, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    .padding(.bottom, DesignConstants.Spacing.step2x)
                    .padding(.leading, DesignConstants.Spacing.step2x)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func fileChip(filename: String) -> some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Image(systemName: "doc.fill")
                .font(.system(size: 28))
                .foregroundStyle(.colorTextSecondary)
            Text(filename)
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
        .frame(width: chipSize, height: chipSize)
        .background(.colorFillSubtle)
        .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
    }

    @ViewBuilder
    private func voiceMemoChip(duration: TimeInterval, levels: [Float]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(formattedDuration(duration))
                .font(.caption2)
                .foregroundStyle(.white)
                .monospacedDigit()
            Spacer(minLength: 0)
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                VoiceMemoWaveformView(
                    levels: levels,
                    progress: 0,
                    playedColor: .white,
                    unplayedColor: .white.opacity(0.4)
                )
                .frame(height: 24)
            }
        }
        .padding(DesignConstants.Spacing.step3x)
        .frame(width: chipSize, height: chipSize)
        .background(.colorLava)
        .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
    }

    @ViewBuilder
    private func connectionChip(identifier: String) -> some View {
        let imageName: String? = AgentBuilderConnection(rawValue: identifier)?.chipImageName
        Group {
            if let imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.colorFillSubtle
            }
        }
        .frame(width: chipSize, height: chipSize)
        .clipShape(.rect(cornerRadius: DesignConstants.Spacing.step4x))
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private let chipSize: CGFloat = 80
}

/// Chip image with the same cache-first strategy as
/// `ReplyReferencePhotoPreview`: image cache first (the send pipeline caches
/// the staged image under both the tracking key and the stored-JSON key),
/// then the thumbnail embedded in the stored attachment JSON. Rows written
/// before photo bundle entries embedded thumbnails - and the brief pre-upload
/// window where the row still carries a tracking key - resolve via the cache
/// tier instead of sticking on the gray placeholder. When the cache has
/// nothing for the key, the embedded thumbnail bytes are written into it so
/// later renders are plain cache hits.
private struct AgentBuilderChipThumbnail: View {
    let attachmentKey: String
    let thumbnailData: Data?

    @State private var loadedImage: UIImage?
    @State private var loadedFromEmbeddedThumbnail: Bool = false

    init(attachmentKey: String, thumbnailData: Data?) {
        self.attachmentKey = attachmentKey
        self.thumbnailData = thumbnailData
        if let cached = ImageCache.shared.image(for: attachmentKey) {
            _loadedImage = State(initialValue: cached)
        } else if let thumbnailData, let image = UIImage(data: thumbnailData) {
            _loadedImage = State(initialValue: image)
            _loadedFromEmbeddedThumbnail = State(initialValue: true)
        }
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.colorFillSubtle
            }
        }
        .task(id: attachmentKey) {
            await resolveFromCache()
        }
    }

    /// Prefer the cached image (memory, then disk) over the embedded
    /// thumbnail: on the sender's device the cache holds the full-quality
    /// staged photo. If the cache misses entirely, seed it with the embedded
    /// thumbnail bytes; the disk write skips existing files, so a full-size
    /// cached image is never replaced by the chip-sized thumbnail.
    private func resolveFromCache() async {
        guard loadedImage == nil || loadedFromEmbeddedThumbnail else { return }
        if let cached = await ImageCache.shared.imageAsync(for: attachmentKey) {
            loadedImage = cached
            loadedFromEmbeddedThumbnail = false
            return
        }
        guard let thumbnailData else { return }
        ImageCache.shared.cacheData(thumbnailData, for: attachmentKey, storageTier: .persistent)
    }
}

#Preview {
    let content = AgentBuilderCardContent(
        id: "preview",
        prompt: "Help me plan a backpacking trip across Patagonia. I want to camp 4 nights and finish in El Chaltén.",
        attachments: [
            HydratedAttachment(key: "preview-photo", mimeType: "image/jpeg"),
            HydratedAttachment(key: "preview-file", mimeType: "application/pdf", filename: "itinerary.pdf"),
            HydratedAttachment(
                key: "preview-voice",
                mimeType: "audio/m4a",
                duration: 18,
                waveformLevels: Array(repeating: 0.6, count: 40)
            ),
        ],
        connectionIdentifiers: ["googleCalendar"]
    )
    return AgentBuilderSummaryView(content: content)
        .padding()
}
