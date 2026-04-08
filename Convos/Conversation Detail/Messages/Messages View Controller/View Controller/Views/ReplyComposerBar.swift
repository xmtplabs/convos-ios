import AVFoundation
import ConvosCore
import SwiftUI

struct ReplyComposerBar: View {
    let message: AnyMessage
    let shouldBlurPhotos: Bool
    let onDismiss: () -> Void

    private var senderName: String {
        message.sender.profile.displayName
    }

    private var previewText: String {
        switch message.content {
        case .text(let text):
            return String(text.prefix(50))
        case .emoji(let emoji):
            return emoji
        case .attachment(let attachment):
            return replyLabel(for: attachment)
        case .attachments(let attachments):
            if let first = attachments.first { return replyLabel(for: first) }
            return "Photo"
        case .invite:
            return "Invite"
        case .linkPreview(let preview):
            return preview.title ?? preview.displayHost
        default:
            return ""
        }
    }

    private var attachment: HydratedAttachment? {
        switch message.content {
        case .attachment(let attachment):
            return attachment
        case .attachments(let attachments):
            return attachments.first
        default:
            return nil
        }
    }

    private var shouldBlurAttachment: Bool {
        guard let attachment else { return false }
        if message.sender.isCurrentUser {
            return attachment.isHiddenByOwner
        }
        return shouldBlurPhotos && !attachment.isRevealed
    }

    private var isVideo: Bool {
        attachment?.mediaType == .video
    }

    private var isFile: Bool {
        attachment?.mediaType == .file
    }

    private var isAudio: Bool {
        attachment?.mediaType == .audio
    }

    private func replyLabel(for attachment: HydratedAttachment) -> String {
        if attachment.mediaType == .file, let filename = attachment.filename {
            return filename
        }
        return attachment.mediaType.previewLabel
            .replacingOccurrences(of: "a ", with: "")
            .capitalized
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            if isAudio {
                Image(systemName: "waveform")
                    .font(.system(size: 14))
                    .foregroundStyle(.colorTextSecondary)
                    .frame(width: 40, height: 40)
            } else if let attachment {
                ReplyPhotoThumbnail(
                    attachmentKey: attachment.key,
                    thumbnailData: attachment.thumbnailData,
                    shouldBlur: shouldBlurAttachment,
                    isVideo: isVideo
                )
            }

            VStack(alignment: .leading, spacing: 2.0) {
                HStack(spacing: 4.0) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(DesignConstants.Fonts.caption3)
                        .foregroundStyle(.colorTextTertiary)
                    Text(senderName)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }

                Text(previewText)
                    .font(.footnote)
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)
            }

            Spacer()

            let action = { onDismiss() }
            Button(action: action) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.colorTextTertiary)
                    .font(.title2)
                    .padding(.horizontal, 3.0)
            }
            .accessibilityLabel("Cancel reply")
            .accessibilityIdentifier("cancel-reply-button")
        }
        .padding(.leading, attachment != nil ? DesignConstants.Spacing.step2x : DesignConstants.Spacing.step4x)
        .padding(.trailing, DesignConstants.Spacing.step2x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: attachment != nil ? 16.0 : 26.0))
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.bottom, DesignConstants.Spacing.stepHalf)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to \(senderName): \(previewText)")
        .accessibilityIdentifier("reply-composer-bar")
    }
}

private struct ReplyPhotoThumbnail: View {
    let attachmentKey: String
    let thumbnailData: Data?
    let shouldBlur: Bool
    var isVideo: Bool = false

    @State private var loadedImage: UIImage?

    private static let loader: RemoteAttachmentLoader = RemoteAttachmentLoader()
    private static let thumbnailSize: CGFloat = 40.0

    init(attachmentKey: String, thumbnailData: Data?, shouldBlur: Bool, isVideo: Bool = false) {
        self.attachmentKey = attachmentKey
        self.thumbnailData = thumbnailData
        self.shouldBlur = shouldBlur
        self.isVideo = isVideo

        if isVideo, let thumbnailData, let thumb = UIImage(data: thumbnailData) {
            _loadedImage = State(initialValue: thumb)
        } else {
            _loadedImage = State(initialValue: ImageCache.shared.image(for: attachmentKey))
        }
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .blur(radius: shouldBlur ? 8 : 0)
                    .opacity(shouldBlur ? 0.5 : 1.0)
                    .clipShape(RoundedRectangle(cornerRadius: 8.0))
                    .overlay {
                        if isVideo, !shouldBlur {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 8.0)
                    .fill(.quaternary)
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            }
        }
        .task {
            guard loadedImage == nil else { return }
            if let cachedImage = await ImageCache.shared.imageAsync(for: attachmentKey) {
                loadedImage = cachedImage
                return
            }
            do {
                if isVideo {
                    let loaded = try await Self.loader.loadAttachmentData(from: attachmentKey)
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("reply-thumb-\(UUID().uuidString).mp4")
                    try loaded.data.write(to: tempURL)
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    let asset = AVURLAsset(url: tempURL)
                    let thumbnail = try await VideoCompressionService().generateThumbnail(for: asset)
                    if let image = UIImage(data: thumbnail) {
                        ImageCache.shared.cacheImage(image, for: attachmentKey, storageTier: .persistent)
                        loadedImage = image
                    }
                    return
                }

                let data = try await Self.loader.loadImageData(from: attachmentKey)
                if let image = UIImage(data: data) {
                    loadedImage = image
                }
            } catch {
                Log.error("Failed to load reply photo thumbnail: \(error)")
            }
        }
    }
}

#Preview("Reply Composer Bar") {
    VStack {
        Spacer()
        ReplyComposerBar(
            message: .message(Message.mock(
                text: "What do you think about the new design?",
                sender: .mock(isCurrentUser: false, name: "Louis"),
                status: .published
            ), .existing),
            shouldBlurPhotos: false,
            onDismiss: {}
        )
    }
}

#Preview("Reply Composer Bar - Long Text") {
    VStack {
        Spacer()
        ReplyComposerBar(
            message: .message(Message.mock(
                text: "I was thinking we could implement a new feature that allows users to customize their profile",
                sender: .mock(isCurrentUser: false, name: "Shane"),
                status: .published
            ), .existing),
            shouldBlurPhotos: false,
            onDismiss: {}
        )
    }
}
