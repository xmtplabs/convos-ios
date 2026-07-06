#if canImport(UIKit)
import AVFoundation
import ConvosCore
import SwiftUI

public struct ReplyComposerBar: View {
    let message: AnyMessage
    var audioTranscriptText: String?
    let onDismiss: () -> Void

    public init(message: AnyMessage, audioTranscriptText: String? = nil, onDismiss: @escaping () -> Void) {
        self.message = message
        self.audioTranscriptText = audioTranscriptText
        self.onDismiss = onDismiss
    }

    @Environment(\.agentShareResolver) private var agentShareResolver: any AgentShareResolving
    @State private var resolvedHTMLTitle: String?
    @State private var resolvedAgentShare: AgentShareInfo?

    private var senderName: String {
        message.sender.profile.displayName
    }

    private var previewText: String {
        if isAudio, let audioTranscriptText, !audioTranscriptText.isEmpty {
            return audioTranscriptText
        }
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
        case .agentShare:
            let name = resolvedAgentShare?.displayName
            if let name, !name.isEmpty {
                return name
            }
            return "Agent"
        case .linkPreview(let preview):
            return preview.title ?? preview.displayHost
        default:
            return ""
        }
    }

    private var htmlAttachment: HydratedAttachment? {
        guard let attachment, attachment.isHTMLFile else { return nil }
        return attachment
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

    private var agentShare: MessageAgentShare? {
        if case .agentShare(let share) = message.content {
            return share
        }
        return nil
    }

    private var hasLeadingThumbnail: Bool {
        attachment != nil || agentShare != nil
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
        if attachment.isHTMLFile, let title = resolvedHTMLTitle, !title.isEmpty {
            return title
        }
        if attachment.mediaType == .file, let filename = attachment.filename {
            return filename
        }
        return attachment.mediaType.previewLabel
            .replacingOccurrences(of: "a ", with: "")
            .capitalized
    }

    public var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            if isAudio {
                Image(systemName: "waveform")
                    .font(.system(size: 14))
                    .foregroundStyle(.colorTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.colorFillSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let htmlAttachment {
                ReplyHTMLThumbnail(attachment: htmlAttachment)
            } else if let attachment {
                ReplyPhotoThumbnail(
                    attachmentKey: attachment.key,
                    thumbnailData: attachment.thumbnailData,
                    isVideo: isVideo
                )
            } else if agentShare != nil {
                ReplyAgentShareThumbnail(emoji: resolvedAgentShare?.emoji)
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
        .padding(.leading, hasLeadingThumbnail ? DesignConstants.Spacing.step2x : DesignConstants.Spacing.step4x)
        .padding(.trailing, DesignConstants.Spacing.step2x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: hasLeadingThumbnail ? 16.0 : 26.0))
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.bottom, DesignConstants.Spacing.stepHalf)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to \(senderName): \(previewText)")
        .accessibilityIdentifier("reply-composer-bar")
        .task(id: htmlAttachment?.key) {
            await loadHTMLTitle()
        }
        .task(id: agentShare?.identifier) {
            await resolveAgentShare()
        }
    }

    private func resolveAgentShare() async {
        guard let agentShare else {
            resolvedAgentShare = nil
            return
        }
        resolvedAgentShare = await agentShareResolver.resolve(identifier: agentShare.identifier)
    }

    private func loadHTMLTitle() async {
        guard let attachment = htmlAttachment else {
            resolvedHTMLTitle = nil
            return
        }
        if let cached = HTMLPageMetadata.shared.cachedTitle(for: attachment.key) {
            resolvedHTMLTitle = cached
            return
        }
        resolvedHTMLTitle = nil
        do {
            let fileURL = try await FileAttachmentLoader.loadFile(for: attachment)
            resolvedHTMLTitle = await HTMLPageMetadata.shared.title(for: attachment.key, fileURL: fileURL)
        } catch {
            Log.error("Failed to load HTML page title for reply composer: \(error)")
            resolvedHTMLTitle = nil
        }
    }
}

private struct ReplyHTMLThumbnail: View {
    let attachment: HydratedAttachment

    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var loadedImage: UIImage?

    private static let thumbnailSize: CGFloat = 40.0

    init(attachment: HydratedAttachment) {
        self.attachment = attachment
        _loadedImage = State(initialValue: HTMLThumbnailRenderer.shared.cachedThumbnail(
            for: attachment.key,
            appearance: .light
        ))
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .clipShape(RoundedRectangle(cornerRadius: 8.0))
            } else {
                RoundedRectangle(cornerRadius: 8.0)
                    .fill(.quaternary)
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            }
        }
        .task(id: AttachmentColorSchemeKey(key: attachment.key, scheme: colorScheme)) {
            let appearance = colorScheme.uiUserInterfaceStyle
            loadedImage = HTMLThumbnailRenderer.shared.cachedThumbnail(
                for: attachment.key,
                appearance: appearance
            )
            guard loadedImage == nil else { return }
            do {
                let fileURL = try await FileAttachmentLoader.loadFile(for: attachment)
                loadedImage = await HTMLThumbnailRenderer.shared.thumbnail(
                    for: attachment.key,
                    fileURL: fileURL,
                    appearance: appearance
                )
            } catch {
                Log.error("Failed to load HTML reply composer thumbnail: \(error)")
            }
        }
    }
}

private struct ReplyPhotoThumbnail: View {
    let attachmentKey: String
    let thumbnailData: Data?
    var isVideo: Bool = false

    @State private var loadedImage: UIImage?

    private static let loader: RemoteAttachmentLoader = RemoteAttachmentLoader()
    private static let thumbnailSize: CGFloat = 40.0

    init(attachmentKey: String, thumbnailData: Data?, isVideo: Bool = false) {
        self.attachmentKey = attachmentKey
        self.thumbnailData = thumbnailData
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
                    .clipShape(RoundedRectangle(cornerRadius: 8.0))
                    .overlay {
                        if isVideo {
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

private struct ReplyAgentShareThumbnail: View {
    let emoji: String?

    private static let thumbnailSize: CGFloat = 40.0
    private static let cornerRadius: CGFloat = 8.0

    var body: some View {
        let emojiFontSize: CGFloat = Self.thumbnailSize * 0.43
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(Color.colorLava)
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .overlay {
                if let emoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.system(size: emojiFontSize, weight: .semibold, design: .rounded))
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
            onDismiss: {}
        )
    }
}

#Preview("Reply Composer Bar - Agent Share") {
    VStack {
        Spacer()
        ReplyComposerBar(
            message: .message(Message.mock(
                content: .agentShare(.mock),
                sender: .mock(isCurrentUser: false, name: "Louis"),
                status: .published
            ), .existing),
            onDismiss: {}
        )
    }
}
#endif
