import AVKit
import ConvosCore
import ConvosLogging
import SwiftUI
import UIKit

struct MessagesGroupItemView: View {
    let message: AnyMessage
    let bubbleType: MessageBubbleType
    let shouldBlurPhotos: Bool
    let onTapAvatar: (AnyMessage) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onReply: (AnyMessage) -> Void
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    var omitTrailingPadding: Bool = false

    @State private var isAppearing: Bool = true
    @State private var hasAnimated: Bool = false

    private var animates: Bool {
        message.origin == .inserted
    }

    private var trailingPadding: CGFloat {
        omitTrailingPadding ? 0 : DesignConstants.Spacing.step4x
    }

    var body: some View {
        VStack(alignment: message.sender.isCurrentUser ? .trailing : .leading, spacing: 0.0) {
            if case .reply(let reply, _) = message {
                ReplyReferenceView(
                    replySender: reply.sender,
                    parentMessage: reply.parentMessage,
                    isOutgoing: message.sender.isCurrentUser,
                    shouldBlurPhotos: shouldBlurPhotos,
                    onTapAvatar: { onTapAvatar(.message(reply.parentMessage, .existing)) },
                    onTapInvite: onTapInvite,
                    onPhotoRevealed: onPhotoRevealed,
                    onPhotoHidden: onPhotoHidden
                )
                .padding(.leading, !message.sender.isCurrentUser && message.content.isFullBleedAttachment
                    ? DesignConstants.Spacing.step4x
                    : 0.0)
            }
            messageContent
        }
        .id("messages-group-item-view-\(message.messageId)")
        .transition(
            .asymmetric(
                insertion: .identity,
                removal: .opacity
            )
        )
        .onAppear {
            guard isAppearing, !hasAnimated else { return }
            hasAnimated = true

            if animates {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isAppearing = false
                }
            } else {
                withAnimation(.none) {
                    isAppearing = false
                }
            }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.content {
        case .text(let text):
            MessageBubble(
                style: message.content.isEmoji ? .none : bubbleType,
                message: text,
                isOutgoing: message.sender.isCurrentUser,
                profile: message.sender.profile
            )
            .messageGesture(
                message: message,
                bubbleStyle: message.content.isEmoji ? .none : bubbleType,
                onReply: onReply
            )
            .id("bubble-\(message.messageId)")
            .scaleEffect(isAppearing ? 0.9 : 1.0)
            .rotationEffect(
                .radians(
                    isAppearing
                    ? (message.source == .incoming ? -0.05 : 0.05)
                    : 0
                )
            )
            .offset(
                x: isAppearing
                ? (message.source == .incoming ? -20 : 20)
                : 0,
                y: isAppearing ? 40 : 0
            )
            .padding(.trailing, trailingPadding)

        case .emoji(let text):
            EmojiBubble(
                emoji: text,
                isOutgoing: message.sender.isCurrentUser,
                profile: message.sender.profile
            )
            .messageGesture(
                message: message,
                bubbleStyle: .none,
                onReply: onReply
            )
            .id("emoji-bubble-\(message.messageId)")
            .opacity(isAppearing ? 0.0 : 1.0)
            .blur(radius: isAppearing ? 10.0 : 0.0)
            .scaleEffect(isAppearing ? 0.0 : 1.0)
            .rotationEffect(
                .radians(
                    isAppearing
                    ? (message.source == .incoming ? -0.10 : 0.10)
                    : 0
                )
            )
            .offset(
                x: isAppearing
                ? (message.source == .incoming ? -200 : 200)
                : 0,
                y: isAppearing ? 40 : 0
            )
            .padding(.trailing, trailingPadding)

        case .invite(let invite):
            MessageInviteContainerView(
                invite: invite,
                style: bubbleType,
                isOutgoing: message.source == .outgoing,
                profile: message.sender.profile,
                onTapInvite: onTapInvite,
                onTapAvatar: { onTapAvatar(message) }
            )
            .messageGesture(
                message: message,
                bubbleStyle: bubbleType,
                onSingleTap: { onTapInvite(invite) },
                onReply: onReply
            )
            .id("message-invite-\(message.messageId)")
            .scaleEffect(isAppearing ? 0.9 : 1.0)
            .rotationEffect(
                .radians(
                    isAppearing
                    ? (message.source == .incoming ? -0.05 : 0.05)
                    : 0
                )
            )
            .offset(
                x: isAppearing
                ? (message.source == .incoming ? -20 : 20)
                : 0,
                y: isAppearing ? 40 : 0
            )
            .padding(.trailing, trailingPadding)

        case .linkPreview(let preview):
            LinkPreviewBubbleView(
                preview: preview,
                style: bubbleType,
                isOutgoing: message.source == .outgoing,
                profile: message.sender.profile,
                messageId: message.messageId
            )
            .messageGesture(
                message: message,
                bubbleStyle: bubbleType,
                onSingleTap: {
                    if let url = preview.resolvedURL {
                        UIApplication.shared.open(url)
                    }
                },
                onReply: onReply
            )
            .id("link-preview-\(message.messageId)")
            .scaleEffect(isAppearing ? 0.9 : 1.0)
            .rotationEffect(
                .radians(
                    isAppearing
                    ? (message.source == .incoming ? -0.05 : 0.05)
                    : 0
                )
            )
            .offset(
                x: isAppearing
                ? (message.source == .incoming ? -20 : 20)
                : 0,
                y: isAppearing ? 40 : 0
            )
            .padding(.trailing, trailingPadding)

        case .attachment(let attachment):
            attachmentView(for: attachment)

        case .attachments(let attachments):
            if let attachment = attachments.first {
                attachmentView(for: attachment)
            }

        case .update, .assistantJoinRequest:
            EmptyView()
        }
    }

    @ViewBuilder
    private func attachmentView(for attachment: HydratedAttachment) -> some View {
        let isBlurred = attachment.isHiddenByOwner || (!message.sender.isCurrentUser && shouldBlurPhotos && !attachment.isRevealed)

        VideoTapAttachmentView(
            attachment: attachment,
            message: message,
            isOutgoing: message.sender.isCurrentUser,
            profile: message.sender.profile,
            shouldBlurPhotos: shouldBlurPhotos,
            isBlurred: isBlurred,
            onPhotoRevealed: onPhotoRevealed,
            onPhotoDimensionsLoaded: onPhotoDimensionsLoaded,
            onReply: onReply
        )
        .id(message.messageId)
    }
}

// MARK: - Attachment Views

private struct VideoTapAttachmentView: View {
    let attachment: HydratedAttachment
    let message: AnyMessage
    let isOutgoing: Bool
    let profile: Profile
    let shouldBlurPhotos: Bool
    let isBlurred: Bool
    let onPhotoRevealed: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let onReply: (AnyMessage) -> Void

    @State private var videoPlayTrigger: Bool = false

    var body: some View {
        AttachmentPlaceholder(
            attachment: attachment,
            isOutgoing: isOutgoing,
            profile: profile,
            shouldBlurPhotos: shouldBlurPhotos,
            cornerRadius: 0,
            videoPlayTrigger: $videoPlayTrigger,
            onDimensionsLoaded: { width, height in
                onPhotoDimensionsLoaded(attachment.key, width, height)
            }
        )
        .messageGesture(
            message: message,
            bubbleStyle: .normal,
            onSingleTap: singleTapAction,
            onReply: onReply
        )
    }

    private var singleTapAction: (() -> Void)? {
        if isBlurred {
            return { onPhotoRevealed(attachment.key) }
        } else if attachment.mediaType == .video {
            return { videoPlayTrigger.toggle() }
        }
        return nil
    }
}

private actor VideoURLCache {
    static let shared: VideoURLCache = VideoURLCache()
    private var cache: [String: URL] = [:]

    func url(for key: String) -> URL? {
        cache[key]
    }

    func set(_ url: URL, for key: String) {
        cache[key] = url
    }
}

private struct AttachmentPlaceholder: View {
    static let maxPhotoWidth: CGFloat = 430
    static let videoPlaybackStarted: Notification.Name = Notification.Name("AttachmentPlaceholder.videoPlaybackStarted")

    let attachment: HydratedAttachment
    let isOutgoing: Bool
    let profile: Profile
    let shouldBlurPhotos: Bool
    var cornerRadius: CGFloat = 0
    @Binding var videoPlayTrigger: Bool
    let onDimensionsLoaded: (Int, Int) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    @State private var loadedImage: UIImage?
    @State private var isLoading: Bool = true
    @State private var loadError: Error?
    @State private var inlinePlayer: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var isLoadingVideo: Bool = false
    @State private var videoLoadFailed: Bool = false
    @State private var instanceID: UUID = UUID()
    @Environment(\.messagePressed) private var isPressed: Bool

    private static let loader: RemoteAttachmentLoader = RemoteAttachmentLoader()

    private var shouldBlur: Bool {
        if attachment.isHiddenByOwner { return true }
        if isOutgoing { return false }
        return shouldBlurPhotos && !attachment.isRevealed
    }

    private var showBlurOverlay: Bool {
        shouldBlur
    }

    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    private var blurRadius: CGFloat {
        guard showBlurOverlay else { return 0 }
        return isPressed ? 80 : 96
    }

    private var placeholderAspectRatio: CGFloat {
        attachment.aspectRatio ?? (4.0 / 3.0)
    }

    private var isVideo: Bool {
        attachment.mediaType == .video
    }

    var body: some View {
        Group {
            if let player = inlinePlayer {
                ZStack(alignment: isOutgoing ? .bottomTrailing : .topLeading) {
                    InlineVideoPlayerView(player: player)
                        .scaleEffect(showBlurOverlay ? 1.65 : 1.0)
                        .blur(radius: showBlurOverlay ? blurRadius : 0)

                    if showBlurOverlay, !isOutgoing {
                        PhotoBlurOverlayContent()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    }

                    if !isPlaying, !shouldBlur, !videoLoadFailed {
                        videoOverlay
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if !isPlaying {
                        PhotoSenderLabel(profile: profile, isOutgoing: isOutgoing)
                    }
                }
                .aspectRatio(placeholderAspectRatio, contentMode: .fit)
                .clipped()
                .overlay(alignment: isOutgoing ? .bottom : .top) {
                    PhotoEdgeGradient(isOutgoing: isOutgoing)
                }
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: isRegularWidth ? DesignConstants.CornerRadius.medium : 0))
                .frame(maxWidth: isRegularWidth ? Self.maxPhotoWidth : .infinity)
                .frame(maxWidth: .infinity, alignment: isRegularWidth ? (isOutgoing ? .trailing : .leading) : .leading)
                .padding(isRegularWidth ? (isOutgoing ? .trailing : .leading) : [], DesignConstants.Spacing.step4x)
                .animation(.easeOut(duration: 0.25), value: showBlurOverlay)
            } else if let image = loadedImage {
                ZStack {
                    photoContent(image: image)

                    if isVideo, !shouldBlur, !videoLoadFailed {
                        if isLoadingVideo {
                            ProgressView()
                                .tint(.white)
                        } else {
                            videoOverlay
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: isRegularWidth ? DesignConstants.CornerRadius.medium : 0))
                .frame(maxWidth: isRegularWidth ? Self.maxPhotoWidth : .infinity)
                .frame(maxWidth: .infinity, alignment: isRegularWidth ? (isOutgoing ? .trailing : .leading) : .leading)
                .padding(isRegularWidth ? (isOutgoing ? .trailing : .leading) : [], DesignConstants.Spacing.step4x)
            } else if isLoading {
                loadingPlaceholder
            } else {
                errorPlaceholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityLabel(isVideo ? "Video message" : "Photo message")
        .onChange(of: videoPlayTrigger) {
            handleVideoPlayTap()
        }
        .onChange(of: shouldBlur) {
            if shouldBlur, isPlaying {
                inlinePlayer?.pause()
                isPlaying = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let finishedItem = notification.object as? AVPlayerItem,
                  finishedItem === inlinePlayer?.currentItem
            else { return }
            isPlaying = false
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.videoPlaybackStarted)) { notification in
            guard let senderID = notification.object as? UUID,
                  senderID != instanceID,
                  isPlaying
            else { return }
            inlinePlayer?.pause()
            isPlaying = false
        }
        .task {
            await loadAttachment()
        }
    }

    @ViewBuilder
    private var videoOverlay: some View {
        ZStack {
            Image(systemName: "play.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                .accessibilityIdentifier("video-play-button")
        }

        if let duration = attachment.duration {
            VStack {
                Spacer()
                HStack {
                    if !isOutgoing { Spacer() }
                    Text(formatDuration(duration))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .accessibilityIdentifier("video-duration-badge")
                    if isOutgoing { Spacer() }
                }
                .padding(DesignConstants.Spacing.step4x)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    private func handleVideoPlayTap() {
        guard isVideo, !shouldBlur else { return }

        if let player = inlinePlayer {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)

                let atEnd: Bool = {
                    guard let item = player.currentItem,
                          item.duration.seconds.isFinite
                    else { return false }
                    return CMTimeGetSeconds(player.currentTime()) >= item.duration.seconds - 0.1
                }()

                if atEnd {
                    let id = instanceID
                    player.seek(to: .zero) { [weak player] finished in
                        guard finished else { return }
                        DispatchQueue.main.async {
                            player?.play()
                        }
                    }
                    isPlaying = true
                    NotificationCenter.default.post(name: Self.videoPlaybackStarted, object: id)
                } else {
                    player.play()
                    isPlaying = true
                    NotificationCenter.default.post(name: Self.videoPlaybackStarted, object: instanceID)
                }
            }
            return
        }
    }

    @ViewBuilder
    private func photoContent(image: UIImage) -> some View {
        ZStack(alignment: isOutgoing ? .bottomTrailing : .topLeading) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(showBlurOverlay ? 1.65 : 1.0)
                .blur(radius: showBlurOverlay ? blurRadius : 0)

            if showBlurOverlay, !isOutgoing {
                PhotoBlurOverlayContent()
                    .transition(.opacity)
            }

            PhotoSenderLabel(profile: profile, isOutgoing: isOutgoing)
        }
        .clipped()
        .overlay(alignment: isOutgoing ? .bottom : .top) {
            PhotoEdgeGradient(isOutgoing: isOutgoing)
        }
        .compositingGroup()
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.25), value: showBlurOverlay)
        .animation(.easeOut(duration: 0.15), value: isPressed)
    }

    private func loadAttachment() async {
        isLoading = true
        loadError = nil

        let cacheKey = attachment.key

        if isVideo {
            if let thumbnailData = attachment.thumbnailData, let thumb = UIImage(data: thumbnailData) {
                loadedImage = thumb
                isLoading = false
                isLoadingVideo = true
                videoLoadFailed = false
            }

            do {
                let videoURL: URL
                if attachment.key.hasPrefix("file://") {
                    let path = String(attachment.key.dropFirst("file://".count))
                    if FileManager.default.fileExists(atPath: path) {
                        videoURL = URL(fileURLWithPath: path)
                    } else {
                        let data = try await recoverInlineAttachmentData(from: path)
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("video_\(UUID().uuidString).mp4")
                        try data.write(to: tempURL)
                        videoURL = tempURL
                    }
                } else if let cached = await VideoURLCache.shared.url(for: attachment.key) {
                    videoURL = cached
                } else {
                    let loaded = try await Self.loader.loadAttachmentData(from: attachment.key)
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("video_\(UUID().uuidString).mp4")
                    try loaded.data.write(to: tempURL)
                    await VideoURLCache.shared.set(tempURL, for: attachment.key)
                    videoURL = tempURL
                }
                let player = AVPlayer(url: videoURL)
                await player.seek(to: .zero)
                inlinePlayer = player
                isLoading = false
                isLoadingVideo = false
            } catch {
                loadError = error
                isLoading = false
                isLoadingVideo = false
                videoLoadFailed = true
                Log.error("Failed to load video: \(error)")
            }
            return
        }

        if let cachedImage = await ImageCache.shared.imageAsync(for: cacheKey) {
            loadedImage = cachedImage
            isLoading = false
            if attachment.width == nil {
                onDimensionsLoaded(Int(cachedImage.size.width), Int(cachedImage.size.height))
            }
            return
        }

        do {
            let imageData: Data

            if attachment.key.hasPrefix("file://") {
                let path = String(attachment.key.dropFirst("file://".count))
                if FileManager.default.fileExists(atPath: path) {
                    imageData = try Data(contentsOf: URL(fileURLWithPath: path))
                } else {
                    imageData = try await recoverInlineAttachmentData(from: path)
                }
            } else if attachment.key.hasPrefix("{") {
                imageData = try await Self.loader.loadImageData(from: attachment.key)
            } else if let url = URL(string: attachment.key) {
                let (data, _) = try await URLSession.shared.data(from: url)
                imageData = data
            } else {
                throw NSError(domain: "AttachmentPlaceholder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid attachment data"])
            }

            if let image = UIImage(data: imageData) {
                loadedImage = image
                ImageCache.shared.cacheImage(image, for: cacheKey, storageTier: .persistent)

                if attachment.width == nil {
                    onDimensionsLoaded(Int(image.size.width), Int(image.size.height))
                }
            } else {
                throw NSError(domain: "AttachmentPlaceholder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create image"])
            }
        } catch {
            loadError = error
            Log.error("Failed to load attachment: \(error)")
        }

        isLoading = false
    }

    private var loadingPlaceholder: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .aspectRatio(placeholderAspectRatio, contentMode: .fit)
            .overlay {
                ProgressView()
            }
            .clipShape(RoundedRectangle(cornerRadius: isRegularWidth ? DesignConstants.CornerRadius.medium : 0))
            .frame(maxWidth: isRegularWidth ? Self.maxPhotoWidth : .infinity)
            .frame(maxWidth: .infinity, alignment: isRegularWidth ? (isOutgoing ? .trailing : .leading) : .leading)
            .padding(isRegularWidth ? (isOutgoing ? .trailing : .leading) : [], DesignConstants.Spacing.step4x)
    }

    private var errorPlaceholder: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .aspectRatio(placeholderAspectRatio, contentMode: .fit)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Failed to load")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isRegularWidth ? DesignConstants.CornerRadius.medium : 0))
            .frame(maxWidth: isRegularWidth ? Self.maxPhotoWidth : .infinity)
            .frame(maxWidth: .infinity, alignment: isRegularWidth ? (isOutgoing ? .trailing : .leading) : .leading)
            .padding(isRegularWidth ? (isOutgoing ? .trailing : .leading) : [], DesignConstants.Spacing.step4x)
    }
}

// MARK: - Sender Label Overlay

struct PhotoSenderLabel: View {
    let profile: Profile
    let isOutgoing: Bool

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            ProfileAvatarView(
                profile: profile,
                profileImage: nil,
                useSystemPlaceholder: false
            )
            .frame(width: DesignConstants.ImageSizes.smallAvatar, height: DesignConstants.ImageSizes.smallAvatar)

            if !isOutgoing {
                Text(profile.displayName)
                    .font(.caption)
                    .foregroundStyle(.white)
            }
        }
        .padding(DesignConstants.Spacing.step4x)
    }
}

// MARK: - Previews

#Preview("Text Message - Incoming") {
    MessagesGroupItemView(
        message: .message(Message.mock(
            text: "Hello, how are you doing today?",
            sender: .mock(isCurrentUser: false),
            status: .published
        ), .existing),
        bubbleType: .normal,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in }
    )
    .padding()
}

#Preview("Text Message - Outgoing") {
    MessagesGroupItemView(
        message: .message(Message.mock(
            text: "I'm doing great, thanks for asking!",
            sender: .mock(isCurrentUser: true),
            status: .published
        ), .existing),
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in }
    )
    .padding()
}

#Preview("Unpublished Message") {
    MessagesGroupItemView(
        message: .message(Message.mock(
            text: "This message is still sending...",
            sender: .mock(isCurrentUser: true),
            status: .unpublished
        ), .existing),
        bubbleType: .normal,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in }
    )
    .padding()
}

#Preview("Emoji Message") {
    MessagesGroupItemView(
        message: .message(Message.mock(
            text: "🎉",
            sender: .mock(isCurrentUser: false),
            status: .published
        ), .existing),
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in }
    )
    .padding()
}

#Preview("Reply - Outgoing") {
    MessagesGroupItemView(
        message: .reply(MessageReply.mock(
            text: "I agree with that!",
            sender: .mock(isCurrentUser: true),
            parentText: "What do you think about the new design?",
            parentSender: .mock(isCurrentUser: false, name: "Jane")
        ), .existing),
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in }
    )
    .padding()
}

#Preview("Reply - Incoming") {
    MessagesGroupItemView(
        message: .reply(MessageReply.mock(
            text: "Sounds good to me",
            sender: .mock(isCurrentUser: false, name: "Alex"),
            parentText: "Let's meet at 3pm tomorrow",
            parentSender: .mock(isCurrentUser: true)
        ), .existing),
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in }
    )
    .padding()
}

private func recoverInlineAttachmentData(from path: String) async throws -> Data {
    let fileURL = URL(fileURLWithPath: path)
    let filename = fileURL.lastPathComponent
    guard let underscoreIndex = filename.firstIndex(of: "_") else {
        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
    }
    let messageId = String(filename[filename.startIndex..<underscoreIndex])
    return try await InlineAttachmentRecovery.shared.recoverData(messageId: messageId)
}

// swiftlint:disable force_unwrapping
#Preview("Single Attachment - Incoming") {
    MessagesGroupItemView(
        message: .message(Message.mockWithAttachment(
            url: URL(string: "https://picsum.photos/400/300")!,
            sender: .mock(isCurrentUser: false),
            status: .published
        ), .existing),
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in }
    )
    .padding()
}

#Preview("Single Attachment - Outgoing") {
    MessagesGroupItemView(
        message: .message(Message.mockWithAttachment(
            url: URL(string: "https://picsum.photos/400/500")!,
            sender: .mock(isCurrentUser: true),
            status: .published
        ), .existing),
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in }
    )
    .padding()
}

#Preview("Single Attachment - Incoming Blurred") {
    MessagesGroupItemView(
        message: .message(Message.mockWithAttachment(
            url: URL(string: "https://picsum.photos/400/300")!,
            sender: .mock(isCurrentUser: false),
            status: .published
        ), .existing),
        bubbleType: .tailed,
        shouldBlurPhotos: true,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in }
    )
    .padding()
}
// swiftlint:enable force_unwrapping
