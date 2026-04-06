import ConvosCore
import ConvosLogging
import SwiftUI
import UIKit

struct ReplyReferenceView: View {
    let replySender: ConversationMember
    let parentMessage: Message
    let isOutgoing: Bool
    let shouldBlurPhotos: Bool
    var onTapAvatar: (() -> Void)?
    var onTapInvite: ((MessageInvite) -> Void)?
    var onPhotoRevealed: ((String) -> Void)?
    var onPhotoHidden: ((String) -> Void)?

    private var previewText: String {
        switch parentMessage.content {
        case .text(let text):
            return String(text.prefix(80))
        case .emoji(let emoji):
            return emoji
        case .attachment(let attachment):
            return replyLabel(for: attachment)
        case .attachments(let attachments):
            if let first = attachments.first { return replyLabel(for: first) }
            return "photo"
        case .invite:
            return "invite"
        case .linkPreview(let preview):
            return preview.title ?? preview.displayHost
        case .update, .assistantJoinRequest:
            return ""
        }
    }

    private func replyLabel(for attachment: HydratedAttachment) -> String {
        if attachment.mediaType == .file, let filename = attachment.filename {
            return filename
        }
        return attachment.mediaType.previewLabel.replacingOccurrences(of: "a ", with: "")
    }

    private var parentAttachment: HydratedAttachment? {
        switch parentMessage.content {
        case .attachment(let attachment):
            return attachment
        case .attachments(let attachments):
            return attachments.first
        default:
            return nil
        }
    }

    private var parentEmoji: String? {
        if case .emoji(let emoji) = parentMessage.content {
            return emoji
        }
        return nil
    }

    private var parentInvite: MessageInvite? {
        if case .invite(let invite) = parentMessage.content {
            return invite
        }
        return nil
    }

    private var parentLinkPreview: LinkPreview? {
        if case .linkPreview(let preview) = parentMessage.content {
            return preview
        }
        return nil
    }

    private var shouldBlurAttachment: Bool {
        guard let parentAttachment else { return false }
        if parentAttachment.isHiddenByOwner { return true }
        if parentMessage.sender.isCurrentUser { return false }
        return shouldBlurPhotos && !parentAttachment.isRevealed
    }

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: DesignConstants.Spacing.stepX) {
            HStack(spacing: DesignConstants.Spacing.stepX) {
                let avatarAction = { if let onTapAvatar { onTapAvatar() } }
                Button(action: avatarAction) {
                    ProfileAvatarView(
                        profile: parentMessage.sender.profile,
                        profileImage: nil,
                        useSystemPlaceholder: false
                    )
                    .frame(width: 16.0, height: 16.0)
                }
                .buttonStyle(.plain)
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(DesignConstants.Fonts.caption3)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, isOutgoing ? 0.0 : DesignConstants.Spacing.step3x)
            .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step3x : 0.0)

            if let attachment = parentAttachment, attachment.mediaType == .audio {
                ReplyReferenceAudioPreview(attachment: attachment)
            } else if let attachment = parentAttachment, attachment.mediaType == .file {
                ReplyReferenceFileBubble(attachment: attachment)
            } else if let attachment = parentAttachment {
                ReplyReferencePhotoPreview(
                    attachmentKey: attachment.key,
                    isVideo: attachment.mediaType == .video,
                    thumbnailData: attachment.thumbnailData,
                    parentMessage: parentMessage,
                    shouldBlur: shouldBlurAttachment,
                    onReveal: { onPhotoRevealed?(attachment.key) },
                    onHide: { onPhotoHidden?(attachment.key) }
                )
            } else if let emoji = parentEmoji {
                Text(emoji)
                    .font(.largeTitle)
            } else if let invite = parentInvite {
                if let onTapInvite {
                    let tapAction = { onTapInvite(invite) }
                    Button(action: tapAction) {
                        ReplyReferenceInvitePreview(invite: invite)
                    }
                    .buttonStyle(.plain)
                } else {
                    ReplyReferenceInvitePreview(invite: invite)
                }
            } else if let preview = parentLinkPreview {
                ReplyReferenceLinkPreview(preview: preview)
                    .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step4x : 0.0)
            } else {
                HStack(spacing: 0) {
                    if isOutgoing {
                        Spacer()
                            .frame(minWidth: 50)
                            .layoutPriority(-1)
                    }
                    replyTextPreview
                    if !isOutgoing {
                        Spacer()
                            .frame(minWidth: 50)
                            .layoutPriority(-1)
                    }
                }
            }
        }
        .padding(.top, DesignConstants.Spacing.stepX)
        .padding(.bottom, DesignConstants.Spacing.stepX)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reply to \(parentMessage.sender.profile.displayName): \(previewText)")
    }

    private var replyTextPreview: some View {
        Text(previewText)
            .font(.caption)
            .foregroundStyle(.colorTextSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .background(
                RoundedRectangle(cornerRadius: Constant.bubbleCornerRadius)
                    .strokeBorder(.colorBorderSubtle, lineWidth: 1.0)
            )
    }

    private enum C {
        static let maxReplyPreviewTextWidth: CGFloat = 220
    }
}

#Preview("Reply - Outgoing") {
    let reply = MessageReply.mock(
        text: "I agree with that!",
        sender: .mock(isCurrentUser: true),
        parentText: "What do you think about the new design?",
        parentSender: .mock(isCurrentUser: false, name: "Louis")
    )
    ReplyReferenceView(
        replySender: reply.sender,
        parentMessage: reply.parentMessage,
        isOutgoing: true,
        shouldBlurPhotos: false
    )
    .padding()
}

#Preview("Reply - Incoming") {
    let reply = MessageReply.mock(
        text: "Sounds good to me",
        sender: .mock(isCurrentUser: false, name: "Alex"),
        parentText: "Let's meet at 3pm tomorrow",
        parentSender: .mock(isCurrentUser: true)
    )
    ReplyReferenceView(
        replySender: reply.sender,
        parentMessage: reply.parentMessage,
        isOutgoing: false,
        shouldBlurPhotos: false
    )
    .padding()
}

#Preview("Reply - Long Text") {
    let reply = MessageReply.mock(
        text: "That's a great point",
        sender: .mock(isCurrentUser: true),
        parentText: "I was thinking we could implement a new feature that allows users to customize their profile with different themes and colors",
        parentSender: .mock(isCurrentUser: false, name: "Sam")
    )
    ReplyReferenceView(
        replySender: reply.sender,
        parentMessage: reply.parentMessage,
        isOutgoing: true,
        shouldBlurPhotos: false
    )
    .padding()
}

// MARK: - Photo Preview

private struct ReplyReferencePhotoPreview: View {
    let attachmentKey: String
    let isVideo: Bool
    let thumbnailData: Data?
    let parentMessage: Message
    let shouldBlur: Bool
    let onReveal: () -> Void
    let onHide: () -> Void

    @Environment(\.messageContextMenuState) private var contextMenuState: MessageContextMenuState
    @State private var loadedImage: UIImage?

    private static let loader: RemoteAttachmentLoader = RemoteAttachmentLoader()
    private static let maxHeight: CGFloat = 80.0

    init(
        attachmentKey: String,
        isVideo: Bool = false,
        thumbnailData: Data? = nil,
        parentMessage: Message,
        shouldBlur: Bool,
        onReveal: @escaping () -> Void,
        onHide: @escaping () -> Void
    ) {
        self.attachmentKey = attachmentKey
        self.isVideo = isVideo
        self.thumbnailData = thumbnailData
        self.parentMessage = parentMessage
        self.shouldBlur = shouldBlur
        self.onReveal = onReveal
        self.onHide = onHide

        if isVideo, let thumbnailData {
            if let thumb = UIImage(data: thumbnailData) {
                _loadedImage = State(initialValue: thumb)
            } else {
                Log.warning("Video thumbnail data failed to decode for attachment: \(attachmentKey)")
                _loadedImage = State(initialValue: ImageCache.shared.image(for: attachmentKey))
            }
        } else {
            _loadedImage = State(initialValue: ImageCache.shared.image(for: attachmentKey))
        }
    }

    @State private var instanceID: UUID = UUID()

    private var isSourceForContextMenu: Bool {
        contextMenuState.isReplyParent && contextMenuState.sourceID == instanceID
    }

    private var imageContent: some View {
        Image(uiImage: loadedImage ?? UIImage())
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: Self.maxHeight)
            .scaleEffect(shouldBlur ? 1.65 : 1.0)
            .blur(radius: shouldBlur ? 96 : 0)
            .background(shouldBlur ? Color.colorBackgroundSurfaceless : .clear)
            .overlay { videoPlayOverlay }
            .opacity(isSourceForContextMenu ? 0 : 1.0)
            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular))
            .contentShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular))
            .onTapGesture {
                if shouldBlur { onReveal() }
            }
            .overlay { longPressOverlay }
    }

    @ViewBuilder
    private var videoPlayOverlay: some View {
        if isVideo, !shouldBlur {
            Image(systemName: "play.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
        }
    }

    private var longPressOverlay: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    let frame = geometry.frame(in: .global)
                    contextMenuState.presentReplyParent(
                        message: .message(parentMessage, .existing),
                        bubbleFrame: frame,
                        sourceID: instanceID
                    )
                }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.regular)
            .fill(.quaternary)
            .frame(width: 60.0, height: Self.maxHeight)
    }

    var body: some View {
        Group {
            if loadedImage != nil {
                imageContent
            } else {
                placeholder
            }
        }
        .task {
            guard loadedImage == nil else { return }
            if let cachedImage = await ImageCache.shared.imageAsync(for: attachmentKey) {
                loadedImage = cachedImage
                return
            }
            guard !isVideo else { return }
            do {
                let data = try await Self.loader.loadImageData(from: attachmentKey)
                if let image = UIImage(data: data) {
                    loadedImage = image
                }
            } catch {
                Log.error("Failed to load reply reference photo: \(error)")
            }
        }
    }
}

// MARK: - Invite Preview

private struct ReplyReferenceInvitePreview: View {
    let invite: MessageInvite
    @State private var cachedImage: UIImage?

    private var title: String {
        if let name = invite.conversationName, !name.isEmpty {
            return "Pop into my convo \"\(name)\""
        }
        return "Pop into my convo"
    }

    private var description: String {
        if let description = invite.conversationDescription, !description.isEmpty {
            return description
        }
        return "convos.org"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image = cachedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image("convosOrangeIcon")
                        .resizable()
                        .tint(.colorTextPrimaryInverted)
                        .foregroundStyle(.colorTextPrimaryInverted)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 56.0)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 128.0)
            .clipped()
            .background(.colorBackgroundMedia)

            VStack(alignment: .leading, spacing: 1.0) {
                Text(title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.colorTextPrimary)
                    .font(.caption)
                    .truncationMode(.tail)
                Text(description)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 210.0, alignment: .leading)
        .background(.colorFillSubtle)
        .clipShape(RoundedRectangle(cornerRadius: Constant.bubbleCornerRadius))
        .cachedImage(for: invite) { image in
            cachedImage = image
        }
    }
}

// MARK: - Link Preview

private struct ReplyReferenceLinkPreview: View {
    let preview: LinkPreview
    @State private var cachedImage: UIImage?
    @State private var ogTitle: String?
    @State private var ogImageURL: String?

    private var displayTitle: String {
        ogTitle ?? preview.title ?? preview.displayHost
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image = cachedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blendMode(.multiply)
                } else {
                    Image(systemName: "link")
                        .font(.title2)
                        .foregroundStyle(.colorTextPrimaryInverted)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 128.0)
            .clipped()
            .background(.colorBackgroundMedia)

            VStack(alignment: .leading, spacing: 1.0) {
                Text(displayTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.colorTextPrimary)
                    .font(.caption)
                    .truncationMode(.tail)
                Text(preview.displayHost)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 210.0, alignment: .leading)
        .background(.colorFillSubtle)
        .clipShape(RoundedRectangle(cornerRadius: Constant.bubbleCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Link preview: \(displayTitle)")
        .task {
            await fetchMetadata()
        }
    }

    private func fetchMetadata() async {
        let metadata = await OpenGraphService.shared.fetchMetadata(for: preview.url)
        if let metadata {
            ogTitle = metadata.title

            if let imageURLString = metadata.imageURL ?? preview.imageURL,
               let imageURL = URL(string: imageURLString) {
                ogImageURL = imageURLString
                let cacheKey = imageURL.absoluteString
                if let cached = await ImageCache.shared.imageAsync(for: cacheKey) {
                    cachedImage = cached
                    return
                }
                if let image = await OpenGraphService.shared.loadImage(from: imageURL) {
                    ImageCache.shared.cacheImage(image, for: cacheKey, storageTier: .cache)
                    cachedImage = image
                }
            }
        }
    }
}

// MARK: - File Reply Preview

private struct ReplyReferenceFileBubble: View {
    let attachment: HydratedAttachment

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.colorFillMinimal)
                Image(systemName: "doc.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename ?? "File")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let label = attachment.fileTypeLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.colorFillMinimal)
        )
    }
}

private struct ReplyReferenceAudioPreview: View {
    let attachment: HydratedAttachment

    @State private var waveformLevels: [Float]?

    private var durationText: String {
        guard let duration = attachment.duration else { return "Audio" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            Image(systemName: "waveform")
                .font(.system(size: 10))
                .foregroundStyle(.colorTextSecondary)

            if let levels = waveformLevels {
                VoiceMemoWaveformView(
                    levels: levels,
                    unplayedColor: .colorTextSecondary.opacity(0.4),
                    barWidth: 1.5,
                    barSpacing: 1
                )
                .frame(width: 60, height: 16)
            }

            Text(durationText)
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.colorFillMinimal)
        )
        .task {
            if let cached = attachment.waveformLevels {
                waveformLevels = cached
                return
            }
            do {
                let loader = RemoteAttachmentLoader()
                let loaded = try await loader.loadAttachmentData(from: attachment.key)
                let levels = await VoiceMemoWaveformAnalyzer.analyzeLevels(from: loaded.data, sampleCount: 30)
                await MainActor.run { waveformLevels = levels }
            } catch {
                Log.error("Failed to load reply audio waveform: \(error)")
            }
        }
    }
}
