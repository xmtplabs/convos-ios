#if canImport(UIKit)
import AVFoundation
import ConvosCore
import SwiftUI
import UIKit

/// The "summary card" cell shown where the user tapped Make. Renders the prompt
/// in a bordered, no-fill box matching the reply-reference preview style (a 1pt
/// `.colorBorderSubtle` rounded rect, no liquid glass), with the attachment chips
/// minus their X buttons. The footer reads "You made an agent" / "<name> created
/// an agent", each followed by "· They'll join soon", with the creator's avatar
/// in front (the same `TextTitleContentView` used by the "Agent is present"
/// row).
///
/// The content is reconstructed by `MessagesListProcessor` from the build's own
/// messages (the prompt + attachment bundle every member receives), so the card
/// is visible to all members and sits in chronological order -- it is no longer
/// pinned to the top from a creator-only local summary.
public struct AgentBuilderSummaryView: View {
    let content: AgentBuilderCardContent
    /// Maps a connection identifier to the app's chip asset name. App-only
    /// concept (the share extension never has connections), so it is a slot
    /// with a placeholder fallback rather than a package dependency.
    let connectionChipImageName: ((String) -> String?)?

    public init(
        content: AgentBuilderCardContent,
        connectionChipImageName: ((String) -> String?)? = nil
    ) {
        self.content = content
        self.connectionChipImageName = connectionChipImageName
    }

    private var footerText: String {
        if content.creatorIsCurrentUser || content.creatorDisplayName.isEmpty {
            return "You made an agent · They'll join soon"
        }
        return "\(content.creatorDisplayName) created an agent · They'll join soon"
    }

    private var hasChips: Bool {
        !content.attachments.isEmpty || !content.connectionIdentifiers.isEmpty
    }

    public var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            TextTitleContentView(title: footerText, profile: content.creatorProfile)
                .frame(maxWidth: .infinity)
            // Cap the card at the message-bubble width (50pt trailing spacer +
            // `bubbleRowWidthCap`), and inset the leading edge by the avatar
            // gutter + row padding so it lines up with incoming message bubbles
            // (which leave room for the sender avatar) rather than the list edge.
            HStack(spacing: 0.0) {
                cardContent
                // Trailing inset matches the leading inset so the card is
                // centered in the view (not just left-aligned with the message
                // column). On regular-width layouts `bubbleRowWidthCap` still
                // caps + leading-pins the row like message bubbles.
                Spacer()
                    .frame(minWidth: Constant.leadingInset)
                    .layoutPriority(-1)
            }
            .bubbleRowWidthCap(alignment: .leading)
            .padding(.leading, Constant.leadingInset)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            if !content.prompt.isEmpty {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    Text(Constant.promptHeader)
                        .font(.caption2)
                        .foregroundStyle(.colorTextSecondary)
                    Text(content.prompt)
                        .font(.caption)
                        .lineSpacing(Constant.promptLineSpacing)
                        .foregroundStyle(.colorTextPrimary)
                }
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
        .background(
            RoundedRectangle(cornerRadius: Constant.cornerRadius)
                .strokeBorder(.colorBorderSubtle, lineWidth: 1.0)
        )
        .contextMenu { promptContextMenu }
    }

    /// Long-press menu for the card. The card isn't a real message (its prompt
    /// is reconstructed from the bundle, not rendered as a bubble), so it has no
    /// standard message actions -- offer a Copy for the prompt text. Empty for
    /// an attachment-only build with no prompt.
    @ViewBuilder private var promptContextMenu: some View {
        if !content.prompt.isEmpty {
            let copyAction = { UIPasteboard.general.string = content.prompt }
            Button(action: copyAction) {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
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
        let imageName: String? = connectionChipImageName?(identifier)
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

    private enum Constant {
        static let promptHeader: String = "What needs done?"
        /// Matches the reply-reference box (`Constant.bubbleCornerRadius`).
        static let cornerRadius: CGFloat = 20
        /// Leading inset for the avatar gutter (`avatarWidth` = `smallAvatar +
        /// step2x`), aligning the card with incoming message bubbles. The row's
        /// `step4x` leading already comes from the cell's `.padding(.horizontal)`,
        /// so it is not added again here.
        static let leadingInset: CGFloat = DesignConstants.ImageSizes.smallAvatar
            + DesignConstants.Spacing.step2x
        /// `.caption` is 12pt with a ~14.3pt intrinsic line height at the default
        /// text size; +1.7 reaches the 16pt line-height from the design spec.
        static let promptLineSpacing: CGFloat = 1.7
    }
}

/// Chip image with the same cache-first strategy as
/// `ReplyReferencePhotoPreview`: image cache first (the send pipeline caches
/// the staged image under both the tracking key and the stored-JSON key),
/// then the thumbnail embedded in the stored attachment JSON. Rows written
/// before photo bundle entries embedded thumbnails - and the brief pre-upload
/// window where the row still carries a tracking key - resolve via the async
/// disk tier instead of sticking on the gray placeholder. The chip only
/// reads from the cache, never writes: the raw attachment key is also the
/// full-size photo renderer's cache key, so seeding the chip-sized thumbnail
/// under it could serve a 240px image where full resolution is expected.
private struct AgentBuilderChipThumbnail: View {
    let attachmentKey: String
    let thumbnailData: Data?

    @State private var loadedImage: UIImage?

    init(attachmentKey: String, thumbnailData: Data?) {
        self.attachmentKey = attachmentKey
        self.thumbnailData = thumbnailData
        if let cached = ImageCache.shared.image(for: attachmentKey) {
            _loadedImage = State(initialValue: cached)
        } else if let thumbnailData, let image = UIImage(data: thumbnailData) {
            _loadedImage = State(initialValue: image)
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
            guard loadedImage == nil else { return }
            loadedImage = await ImageCache.shared.imageAsync(for: attachmentKey)
        }
    }
}
#endif
