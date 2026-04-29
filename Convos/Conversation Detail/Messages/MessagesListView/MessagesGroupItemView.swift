import AVKit
import ConvosCore
import ConvosLogging
import SwiftUI
import UIKit

struct MessagesGroupItemView: View {
    let message: AnyMessage
    let conversationId: String
    let bubbleType: MessageBubbleType
    let shouldBlurPhotos: Bool
    let onTapAvatar: (AnyMessage) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onReply: (AnyMessage) -> Void
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    var onOpenFile: ((HydratedAttachment) -> Void)?
    var onTapReactions: ((AnyMessage) -> Void)?
    var onReaction: ((String, String) -> Void)?
    let onToggleReaction: (String, String) -> Void
    var voiceMemoTranscript: VoiceMemoTranscriptListItem?
    var voiceMemoTranscriptIsTailed: Bool = false
    var onRetryTranscript: ((VoiceMemoTranscriptListItem) -> Void)?
    var parentAudioTranscriptText: String?
    var omitTrailingPadding: Bool = false

    @State private var isAppearing: Bool = true
    @State private var hasAnimated: Bool = false

    private var animates: Bool {
        message.origin == .inserted
    }

    private var trailingPadding: CGFloat {
        omitTrailingPadding ? 0 : DesignConstants.Spacing.step4x
    }

    private var isAudioAttachment: Bool {
        switch message.content {
        case .attachment(let attachment):
            return attachment.mediaType == .audio
        case .attachments(let attachments):
            return attachments.first?.mediaType == .audio
        default:
            return false
        }
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
                    onPhotoHidden: onPhotoHidden,
                    parentAudioTranscriptText: parentAudioTranscriptText
                )
                .padding(.leading, !message.sender.isCurrentUser && message.content.isFullBleedAttachment
                    ? DesignConstants.Spacing.step4x
                    : 0.0)
                .padding(.trailing, trailingPadding)
            }
            messageContent
            if let voiceMemoTranscript, !isAudioAttachment {
                VoiceMemoTranscriptRow(
                    item: voiceMemoTranscript,
                    isTailed: voiceMemoTranscriptIsTailed,
                    onRetryTranscript: onRetryTranscript
                )
                .padding(.top, DesignConstants.Spacing.stepX)
            }
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
            textBubble(text: text)
        case .emoji(let text):
            emojiBubble(text: text)
        case .invite(let invite):
            inviteBubble(invite: invite)
        case .linkPreview(let preview):
            linkPreviewBubble(preview: preview)
        case .attachment(let attachment):
            attachmentView(for: attachment)
        case .attachments(let attachments):
            if let attachment = attachments.first {
                attachmentView(for: attachment)
            }
        case .update, .assistantJoinRequest:
            EmptyView()
        case .connectionGrantRequest(let request):
            connectionGrantRequestBubble(request: request)
        case .connectionEvent, .connectionInvocation, .connectionInvocationResult:
            EmptyView()
        }
    }

    @ViewBuilder
    private func textBubble(text: String) -> some View {
        MessageBubble(
            style: message.content.isEmoji ? .none : bubbleType,
            message: text,
            isOutgoing: message.sender.isCurrentUser,
            profile: message.sender.profile
        )
        .messageGesture(
            message: message,
            bubbleStyle: message.content.isEmoji ? .none : bubbleType,
            onReply: onReply,
            onToggleReaction: onToggleReaction
        )
        .id("bubble-\(message.messageId)")
        .modifier(MessageAppearanceModifier(isAppearing: isAppearing, source: message.source))
        .padding(.trailing, trailingPadding)
    }

    @ViewBuilder
    private func emojiBubble(text: String) -> some View {
        EmojiBubble(
            emoji: text,
            isOutgoing: message.sender.isCurrentUser,
            profile: message.sender.profile
        )
        .messageGesture(
            message: message,
            bubbleStyle: .none,
            onReply: onReply,
            onToggleReaction: onToggleReaction
        )
        .id("emoji-bubble-\(message.messageId)")
        .opacity(isAppearing ? 0.0 : 1.0)
        .blur(radius: isAppearing ? 10.0 : 0.0)
        .scaleEffect(isAppearing ? 0.0 : 1.0)
        .rotationEffect(.radians(isAppearing ? (message.source == .incoming ? -0.10 : 0.10) : 0))
        .offset(
            x: isAppearing ? (message.source == .incoming ? -200 : 200) : 0,
            y: isAppearing ? 40 : 0
        )
        .padding(.trailing, trailingPadding)
    }

    @ViewBuilder
    private func inviteBubble(invite: MessageInvite) -> some View {
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
            onReply: onReply,
            onToggleReaction: onToggleReaction
        )
        .id("message-invite-\(message.messageId)")
        .modifier(MessageAppearanceModifier(isAppearing: isAppearing, source: message.source))
        .padding(.trailing, trailingPadding)
    }

    @ViewBuilder
    private func linkPreviewBubble(preview: LinkPreview) -> some View {
        let openAction: () -> Void = {
            if let url = preview.resolvedURL {
                UIApplication.shared.open(url)
            }
        }
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
            onSingleTap: openAction,
            onReply: onReply,
            onToggleReaction: onToggleReaction
        )
        .id("link-preview-\(message.messageId)")
        .modifier(MessageAppearanceModifier(isAppearing: isAppearing, source: message.source))
        .padding(.trailing, trailingPadding)
    }

    @ViewBuilder
    private func connectionGrantRequestBubble(request: CloudConnectionGrantRequest) -> some View {
        if FeatureFlags.shared.isCloudConnectionsEnabled {
            CloudConnectionGrantRequestCardView(
                request: request,
                conversationId: conversationId,
                sender: message.sender
            )
            .messageGesture(
                message: message,
                bubbleStyle: bubbleType,
                onReply: onReply,
                onToggleReaction: onToggleReaction
            )
            .padding(.trailing, trailingPadding)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func attachmentView(for attachment: HydratedAttachment) -> some View {
        let isBlurred = attachment.isHiddenByOwner || (!message.sender.isCurrentUser && shouldBlurPhotos && !attachment.isRevealed)

        if attachment.mediaType == .audio {
            let playAction: () -> Void = {
                NotificationCenter.default.post(
                    name: .voiceMemoPlaybackRequested,
                    object: nil,
                    userInfo: ["messageId": message.messageId, "attachmentKey": attachment.key]
                )
            }
            MessageContainer(style: bubbleType, isOutgoing: message.sender.isCurrentUser) {
                VoiceMemoBubbleContent(
                    message: message,
                    attachment: attachment,
                    isOutgoing: message.sender.isCurrentUser,
                    player: .shared,
                    isLoading: false,
                    transcript: voiceMemoTranscript,
                    onRetryTranscript: onRetryTranscript
                )
            }
            .padding(.trailing, message.sender.isCurrentUser ? DesignConstants.Spacing.step4x : 0)
            .messageGesture(
                message: message,
                bubbleStyle: bubbleType,
                onSingleTap: playAction,
                onReply: onReply,
                onToggleReaction: onToggleReaction
            )
            .id(message.messageId)
        } else if attachment.mediaType == .file {
            let fileTapAction: () -> Void = { onOpenFile?(attachment) }
            FileAttachmentBubble(
                attachment: attachment,
                style: bubbleType,
                isOutgoing: message.sender.isCurrentUser,
                profile: message.sender.profile
            )
            .messageGesture(
                message: message,
                bubbleStyle: bubbleType,
                onSingleTap: fileTapAction,
                onReply: onReply,
                onToggleReaction: onToggleReaction
            )
            .id(message.messageId)
        } else {
            MediaAttachmentView(
                attachment: attachment,
                message: message,
                isOutgoing: message.sender.isCurrentUser,
                profile: message.sender.profile,
                shouldBlurPhotos: shouldBlurPhotos,
                isBlurred: isBlurred,
                reactions: message.reactions,
                onPhotoRevealed: onPhotoRevealed,
                onPhotoDimensionsLoaded: onPhotoDimensionsLoaded,
                onReply: onReply,
                onToggleReaction: onToggleReaction,
                onTapReactions: { onTapReactions?(message) },
                onTapAvatar: { onTapAvatar(message) },
                onDoubleTapReaction: { onReaction?("❤️", message.messageId) }
            )
            .id(message.messageId)
        }
    }
}

private struct MessageAppearanceModifier: ViewModifier {
    let isAppearing: Bool
    let source: MessageSource

    func body(content: Content) -> some View {
        content
            .scaleEffect(isAppearing ? 0.9 : 1.0)
            .rotationEffect(.radians(isAppearing ? (source == .incoming ? -0.05 : 0.05) : 0))
            .offset(
                x: isAppearing ? (source == .incoming ? -20 : 20) : 0,
                y: isAppearing ? 40 : 0
            )
    }
}

// MARK: - Attachment Views

private struct MediaAttachmentView: View {
    let attachment: HydratedAttachment
    let message: AnyMessage
    let isOutgoing: Bool
    let profile: Profile
    let shouldBlurPhotos: Bool
    let isBlurred: Bool
    var reactions: [MessageReaction] = []
    let onPhotoRevealed: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let onReply: (AnyMessage) -> Void
    let onToggleReaction: (String, String) -> Void
    var onTapReactions: () -> Void = {}
    var onTapAvatar: () -> Void = {}
    var onDoubleTapReaction: (() -> Void)?

    @State private var videoPlayTrigger: Bool = false
    @State private var isPlaying: Bool = false
    @State private var swipeOffset: CGFloat = 0
    @State private var resolvedDuration: Double?
    @State private var pendingPlayAfterReveal: Bool = false
    @State private var reactionsPeekVisible: Bool = false
    @State private var reactionsPeekTask: Task<Void, Never>?
    @State private var pendingPlayingDoubleTapReaction: Bool = false
    @State private var reactionsPeekGeneration: Int = 0
    @State private var playingDoubleTapAnimationTrigger: Int = 0

    private var isVideo: Bool {
        attachment.mediaType == .video
    }

    private var swipeCornerRadius: CGFloat {
        let progress = min(abs(swipeOffset) / 60.0, 1.0)
        return progress * 12.0
    }

    var body: some View {
        AttachmentPlaceholder(
            attachment: attachment,
            isOutgoing: isOutgoing,
            profile: profile,
            shouldBlurPhotos: shouldBlurPhotos,
            cornerRadius: swipeCornerRadius,
            videoPlayTrigger: $videoPlayTrigger,
            isPlaying: $isPlaying,
            resolvedDuration: $resolvedDuration,
            pendingPlayAfterReveal: $pendingPlayAfterReveal,
            onDimensionsLoaded: { width, height in
                onPhotoDimensionsLoaded(attachment.key, width, height)
            }
        )
        .overlay(alignment: .topLeading) {
            if !isPlaying {
                MediaContainerID(profile: profile, onTap: onTapAvatar)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: MessageGestureExclusionFrameKey.self,
                                value: [geometry.frame(in: .global)]
                            )
                        }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isPlaying {
                MediaContainerInfo(
                    isBlurred: isBlurred,
                    isVideo: isVideo,
                    duration: resolvedDuration ?? attachment.duration
                )
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if (!reactions.isEmpty && !isPlaying) || reactionsPeekVisible {
                MediaContainerReax(
                    reactions: reactions,
                    onTap: onTapReactions
                )
                .id(playingDoubleTapAnimationTrigger)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: MessageGestureExclusionFrameKey.self,
                            value: [geometry.frame(in: .global)]
                        )
                    }
                }
                .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
                .animation(.spring(response: 0.34, dampingFraction: 0.72), value: reactionsPeekVisible)
            }
        }
        .onDisappear {
            reactionsPeekTask?.cancel()
        }
        .onChange(of: isPlaying) { _, playing in
            if !playing {
                reactionsPeekTask?.cancel()
                reactionsPeekTask = nil
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    reactionsPeekVisible = false
                }
            }
        }
        .messageGesture(
            message: message,
            bubbleStyle: .normal,
            onSingleTap: singleTapAction,
            onDoubleTap: doubleTapAction,
            onReply: onReply,
            onToggleReaction: onToggleReaction,
            swipeOffset: $swipeOffset
        )
    }

    private var singleTapAction: (() -> Void)? {
        if isBlurred {
            return {
                onPhotoRevealed(attachment.key)
                if isVideo {
                    pendingPlayAfterReveal = true
                }
            }
        } else if isVideo {
            return { videoPlayTrigger.toggle() }
        }
        return nil
    }

    private var doubleTapAction: (() -> Void)? {
        guard isVideo else { return nil }
        return handleDoubleTap
    }

    private func handleDoubleTap() {
        if isPlaying {
            playingDoubleTapAnimationTrigger += 1
            if reactionsPeekVisible {
                reactionsPeekVisible = false
            }
            if currentUserHasHeartReaction == false {
                pendingPlayingDoubleTapReaction = true
            }
            showReactionsPeek(forceShow: true)
        } else {
            onDoubleTapReaction?()
        }
    }

    private var currentUserHasHeartReaction: Bool {
        reactions.contains { reaction in
            reaction.sender.isCurrentUser && reaction.emoji == "❤️"
        }
    }

    private func showReactionsPeek(forceShow: Bool = false) {
        reactionsPeekTask?.cancel()
        reactionsPeekGeneration += 1
        let generation = reactionsPeekGeneration

        guard !reactions.isEmpty || forceShow else {
            if pendingPlayingDoubleTapReaction {
                pendingPlayingDoubleTapReaction = false
                onDoubleTapReaction?()
            }
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
            reactionsPeekVisible = true
        }
        reactionsPeekTask = Task { @MainActor in
            if pendingPlayingDoubleTapReaction {
                pendingPlayingDoubleTapReaction = false
                onDoubleTapReaction?()
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, reactionsPeekGeneration == generation else { return }
            }

            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled, reactionsPeekGeneration == generation else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                reactionsPeekVisible = false
            }
        }
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
    @Binding var isPlaying: Bool
    @Binding var resolvedDuration: Double?
    @Binding var pendingPlayAfterReveal: Bool
    let onDimensionsLoaded: (Int, Int) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    @State private var loadedImage: UIImage?
    @State private var isLoading: Bool = true
    @State private var loadError: Error?
    @State private var inlinePlayer: AVPlayer?
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
        contentGroup
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .accessibilityLabel(isVideo ? "Video message" : "Photo message")
            .onChange(of: videoPlayTrigger) {
                handleVideoPlayTap()
            }
            .onChange(of: shouldBlur) {
                handleBlurChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                handlePlaybackEnd(notification: notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: Self.videoPlaybackStarted)) { notification in
                handlePlaybackStartedElsewhere(notification: notification)
            }
            .task {
                await loadAttachment()
            }
    }

    @ViewBuilder
    private var contentGroup: some View {
        if let player = inlinePlayer {
            inlineVideoView(player: player)
        } else if let image = loadedImage {
            loadedImageView(image: image)
        } else if isLoading {
            loadingPlaceholder
        } else {
            errorPlaceholder
        }
    }

    @ViewBuilder
    private func inlineVideoView(player: AVPlayer) -> some View {
        InlineVideoPlayerView(player: player)
            .scaleEffect(showBlurOverlay ? 1.65 : 1.0)
            .blur(radius: showBlurOverlay ? blurRadius : 0)
            .overlay(alignment: .top) {
                if !isPlaying {
                    MediaTopGradient()
                }
            }
            .overlay {
                if !isPlaying, !videoLoadFailed {
                    videoOverlay
                }
            }
            .aspectRatio(placeholderAspectRatio, contentMode: .fit)
            .clipped()
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: isRegularWidth ? DesignConstants.CornerRadius.medium : 0))
            .frame(maxWidth: isRegularWidth ? Self.maxPhotoWidth : .infinity)
            .frame(maxWidth: .infinity, alignment: isRegularWidth ? (isOutgoing ? .trailing : .leading) : .leading)
            .padding(isRegularWidth ? (isOutgoing ? .trailing : .leading) : [], DesignConstants.Spacing.step4x)
            .animation(.easeOut(duration: 0.25), value: showBlurOverlay)
    }

    @ViewBuilder
    private func loadedImageView(image: UIImage) -> some View {
        ZStack {
            photoContent(image: image)
            if isVideo, !videoLoadFailed {
                if isLoadingVideo {
                    ProgressView().tint(.white)
                } else {
                    videoOverlay
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: isRegularWidth ? DesignConstants.CornerRadius.medium : 0))
        .frame(maxWidth: isRegularWidth ? Self.maxPhotoWidth : .infinity)
        .frame(maxWidth: .infinity, alignment: isRegularWidth ? (isOutgoing ? .trailing : .leading) : .leading)
        .padding(isRegularWidth ? (isOutgoing ? .trailing : .leading) : [], DesignConstants.Spacing.step4x)
    }

    private func handleBlurChange() {
        if shouldBlur, isPlaying {
            inlinePlayer?.pause()
            isPlaying = false
        } else if !shouldBlur, pendingPlayAfterReveal {
            pendingPlayAfterReveal = false
            handleVideoPlayTap()
        }
    }

    private func handlePlaybackEnd(notification: Notification) {
        guard let finishedItem = notification.object as? AVPlayerItem,
              finishedItem === inlinePlayer?.currentItem
        else { return }
        isPlaying = false
    }

    private func handlePlaybackStartedElsewhere(notification: Notification) {
        guard let senderID = notification.object as? UUID,
              senderID != instanceID,
              isPlaying
        else { return }
        inlinePlayer?.pause()
        isPlaying = false
    }

    private var videoOverlay: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 15))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial)
            .background(Color.white.opacity(0.85))
            .clipShape(Circle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("video-play-button")
    }

    private func handleVideoPlayTap() {
        guard isVideo else { return }
        if shouldBlur {
            pendingPlayAfterReveal = true
            return
        }

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
                        guard finished else {
                            DispatchQueue.main.async {
                                isPlaying = false
                            }
                            return
                        }
                        DispatchQueue.main.async {
                            player?.play()
                            isPlaying = true
                            NotificationCenter.default.post(name: Self.videoPlaybackStarted, object: id)
                        }
                    }
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
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .scaleEffect(showBlurOverlay ? 1.65 : 1.0)
            .blur(radius: showBlurOverlay ? blurRadius : 0)
            .overlay(alignment: .top) {
                MediaTopGradient()
            }
            .clipped()
            .compositingGroup()
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.25), value: showBlurOverlay)
            .animation(.easeOut(duration: 0.15), value: isPressed)
    }

    private func loadAttachment() async {
        isLoading = true
        loadError = nil

        if isVideo {
            await loadVideoAttachment()
        } else {
            await loadPhotoAttachment()
        }
    }

    private func loadVideoAttachment() async {
        let cacheKey = attachment.key
        applyVideoThumbnailDataIfAvailable(cacheKey: cacheKey)
        do {
            let videoURL = try await resolveVideoURL(for: attachment.key)
            if attachment.width == nil {
                await loadVideoDimensionsIfPossible(from: videoURL)
            }
            let asset = AVURLAsset(url: videoURL)
            await resolveVideoDurationIfNeeded(asset: asset)
            await generateVideoThumbnailIfNeeded(asset: asset, cacheKey: cacheKey)
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
    }

    private func applyVideoThumbnailDataIfAvailable(cacheKey: String) {
        guard let thumbnailData = attachment.thumbnailData,
              let thumb = UIImage(data: thumbnailData) else {
            return
        }
        loadedImage = thumb
        ImageCache.shared.cacheImage(thumb, for: cacheKey)
        isLoading = false
        isLoadingVideo = true
        videoLoadFailed = false
        if attachment.width == nil {
            onDimensionsLoaded(Int(thumb.size.width), Int(thumb.size.height))
        }
    }

    private func resolveVideoDurationIfNeeded(asset: AVURLAsset) async {
        guard resolvedDuration == nil else { return }
        do {
            let cmDuration = try await asset.load(.duration)
            if cmDuration.seconds.isFinite {
                resolvedDuration = cmDuration.seconds
            } else {
                Log.warning("Resolved non-finite video duration for attachment: \(attachment.key)")
            }
        } catch {
            Log.warning("Failed to resolve video duration for attachment \(attachment.key): \(error.localizedDescription)")
        }
    }

    private func generateVideoThumbnailIfNeeded(asset: AVURLAsset, cacheKey: String) async {
        guard loadedImage == nil else { return }
        let thumbnailData = try? await VideoCompressionService().generateThumbnail(for: asset)
        guard let thumbnailData, let thumb = UIImage(data: thumbnailData) else { return }
        loadedImage = thumb
        ImageCache.shared.cacheImage(thumb, for: cacheKey, storageTier: .persistent)
        if attachment.width == nil {
            onDimensionsLoaded(Int(thumb.size.width), Int(thumb.size.height))
        }
    }

    private func loadPhotoAttachment() async {
        let cacheKey = attachment.key

        if let cachedImage = await ImageCache.shared.imageAsync(for: cacheKey) {
            loadedImage = cachedImage
            isLoading = false
            if attachment.width == nil {
                onDimensionsLoaded(Int(cachedImage.size.width), Int(cachedImage.size.height))
            }
            return
        }

        do {
            let imageData = try await resolveImageData(for: attachment.key)

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

    private func resolveImageData(for key: String) async throws -> Data {
        if key.hasPrefix("file://") {
            let path = String(key.dropFirst("file://".count))
            if FileManager.default.fileExists(atPath: path) {
                return try Data(contentsOf: URL(fileURLWithPath: path))
            }
            return try await recoverInlineAttachmentData(from: path)
        } else if key.hasPrefix("{") {
            return try await Self.loader.loadImageData(from: key)
        } else if let url = URL(string: key) {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
        throw NSError(domain: "AttachmentPlaceholder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid attachment data"])
    }

    /// Reads the natural video dimensions from a decrypted local video file and
    /// reports them via `onDimensionsLoaded` so the aspect ratio is persisted for
    /// future renders. This is the fallback for incoming videos that arrive without
    /// sender-provided dimensions (e.g. inline attachments from clients that do not
    /// populate `StoredRemoteAttachment.mediaWidth`/`mediaHeight`, or remote
    /// attachments without an accompanying thumbnail).
    private func loadVideoDimensionsIfPossible(from videoURL: URL) async {
        let service = VideoCompressionService()
        do {
            let size = try await service.loadVideoDimensions(from: videoURL)
            let width = Int(size.width.rounded())
            let height = Int(size.height.rounded())
            guard width > 0, height > 0 else { return }
            await MainActor.run {
                onDimensionsLoaded(width, height)
            }
        } catch {
            Log.warning("Failed to read video dimensions: \(error)")
        }
    }

    private func resolveVideoURL(for key: String) async throws -> URL {
        if key.hasPrefix("file://") {
            let path = String(key.dropFirst("file://".count))
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            let data = try await recoverInlineAttachmentData(from: path)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("video_\(UUID().uuidString).mp4")
            try data.write(to: tempURL)
            return tempURL
        }
        if let cached = await VideoURLCache.shared.url(for: key) {
            return cached
        }
        let loaded = try await Self.loader.loadAttachmentData(from: key)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("video_\(UUID().uuidString).mp4")
        try loaded.data.write(to: tempURL)
        await VideoURLCache.shared.set(tempURL, for: key)
        return tempURL
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

// MARK: - Media Overlay Containers

private struct MediaContainerID: View {
    let profile: Profile
    var onTap: (() -> Void)?

    var body: some View {
        let tapAction = { onTap?() ?? () }
        Button(action: tapAction) {
            HStack(spacing: 6) {
                ProfileAvatarView(
                    profile: profile,
                    profileImage: nil,
                    useSystemPlaceholder: false
                )
                .frame(width: DesignConstants.ImageSizes.smallAvatar, height: DesignConstants.ImageSizes.smallAvatar)

                Text(profile.displayName)
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            .padding(DesignConstants.Spacing.step4x)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MediaContainerInfo: View {
    let isBlurred: Bool
    let isVideo: Bool
    let duration: Double?

    private var text: String? {
        var parts: [String] = []
        if isBlurred {
            parts.append("Tap to reveal")
        }
        if isVideo, let duration {
            parts.append(formatDuration(duration))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        if let text {
            HStack {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            .frame(height: 56)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .contentShape(Rectangle())
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
}

private struct MediaContainerReax: View {
    let reactions: [MessageReaction]
    let onTap: () -> Void

    private var uniqueEmojis: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for reaction in reactions.sorted(by: { $0.date > $1.date }) where !seen.contains(reaction.emoji) {
            seen.insert(reaction.emoji)
            result.append(reaction.emoji)
        }
        return result
    }

    private var totalCount: Int {
        reactions.count
    }

    private var currentUserHasReacted: Bool {
        reactions.contains { $0.sender.isCurrentUser }
    }

    var body: some View {
        if !reactions.isEmpty {
            let tapAction = { onTap() }
            Button(action: tapAction) {
                reaxContent
                    .padding(DesignConstants.Spacing.step4x)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var reaxContent: some View {
        HStack(spacing: DesignConstants.Spacing.stepHalf) {
            ForEach(uniqueEmojis, id: \.self) { emoji in
                Text(emoji)
                    .font(.callout)
            }
            if totalCount > 1 {
                Text("\(totalCount)")
                    .font(.footnote)
                    .foregroundStyle(.black.opacity(0.6))
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .modifier(ReaxGlassModifier(reacted: currentUserHasReacted))
    }
}

private struct ReaxGlassModifier: ViewModifier {
    let reacted: Bool

    func body(content: Content) -> some View {
        if reacted {
            content.glassEffect(.regular.tint(.white.opacity(0.6)).interactive(), in: .capsule)
        } else {
            content.glassEffect(.clear.interactive(), in: .capsule)
        }
    }
}

private struct MediaTopGradient: View {
    var body: some View {
        VStack(spacing: 0) {
            Color(.colorBorderEdge).frame(height: 1)
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 56)
            .opacity(0.15)
            .blendMode(.multiply)
        }
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
        conversationId: "preview-conversation",
        bubbleType: .normal,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in },
        onToggleReaction: { _, _ in }
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
        conversationId: "preview-conversation",
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in },
        onToggleReaction: { _, _ in }
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
        conversationId: "preview-conversation",
        bubbleType: .normal,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in },
        onToggleReaction: { _, _ in }
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
        conversationId: "preview-conversation",
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in },
        onToggleReaction: { _, _ in }
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
        conversationId: "preview-conversation",
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in },
        onToggleReaction: { _, _ in }
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
        conversationId: "preview-conversation",
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in },
        onToggleReaction: { _, _ in }
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
        conversationId: "preview-conversation",
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in },
        onToggleReaction: { _, _ in }
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
        conversationId: "preview-conversation",
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in },
        onToggleReaction: { _, _ in }
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
        conversationId: "preview-conversation",
        bubbleType: .tailed,
        shouldBlurPhotos: true,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onReply: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in },
        onToggleReaction: { _, _ in }
    )
    .padding()
}
// swiftlint:enable force_unwrapping
