import ConvosCore
import ConvosLogging
import Photos
import SwiftUI
import UIKit

struct MessagesGroupItemView: View {
    let message: AnyMessage
    let bubbleType: MessageBubbleType
    let shouldBlurPhotos: Bool
    let onTapAvatar: (AnyMessage) -> Void
    let onTapInvite: (MessageInvite) -> Void
    let onReply: (AnyMessage) -> Void
    let onDoubleTap: (AnyMessage) -> Void
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void

    @State private var isAppearing: Bool = true
    @State private var hasAnimated: Bool = false
    @State private var swipeOffset: CGFloat = 0

    private var animates: Bool {
        message.origin == .inserted
    }

    private var isReply: Bool {
        if case .reply = message { return true }
        return false
    }

    var body: some View {
        VStack(alignment: message.base.sender.isCurrentUser ? .trailing : .leading, spacing: 0.0) {
            if case .reply(let reply, _) = message {
                ReplyReferenceView(
                    replySender: reply.sender,
                    parentMessage: reply.parentMessage,
                    isOutgoing: message.base.sender.isCurrentUser,
                    shouldBlurPhotos: shouldBlurPhotos,
                    onTapAvatar: { onTapAvatar(.message(reply.parentMessage, .existing)) },
                    onPhotoRevealed: onPhotoRevealed,
                    onPhotoHidden: onPhotoHidden
                )
            }
            switch message.base.content {
            case .text(let text):
                MessageBubble(
                    style: message.base.content.isEmoji ? .none : bubbleType,
                    message: text,
                    isOutgoing: message.base.sender.isCurrentUser,
                    profile: message.base.sender.profile
                )
                .messageInteractions(
                    message: message,
                    bubbleStyle: message.base.content.isEmoji ? .none : bubbleType,
                    onSwipeOffsetChanged: { swipeOffset = $0 },
                    onSwipeEnded: { triggered in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            swipeOffset = 0
                        }
                        if triggered { onReply(message) }
                    }
                )
                .offset(x: swipeOffset)
                .background(alignment: .leading) {
                    if swipeOffset > 0 {
                        let progress = min(swipeOffset / 60.0, 1.0)
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .foregroundStyle(.tertiary)
                            .scaleEffect(0.4 + progress * 0.6)
                            .opacity(Double(progress))
                            .accessibilityHidden(true)
                    }
                }
                .zIndex(200)
                .id("bubble-\(message.base.id)")
                .scaleEffect(isAppearing ? 0.9 : 1.0)
                .rotationEffect(
                    .radians(
                        isAppearing
                        ? (message.base.source == .incoming ? -0.05 : 0.05)
                        : 0
                    )
                )
                .offset(
                    x: isAppearing
                    ? (message.base.source == .incoming ? -20 : 20)
                    : 0,
                    y: isAppearing ? 40 : 0
                )
                .padding(.trailing, DesignConstants.Spacing.step4x)

            case .emoji(let text):
                EmojiBubble(
                    emoji: text,
                    isOutgoing: message.base.sender.isCurrentUser,
                    profile: message.base.sender.profile
                )
                .messageInteractions(
                    message: message,
                    bubbleStyle: .none,
                    onSwipeOffsetChanged: { swipeOffset = $0 },
                    onSwipeEnded: { triggered in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            swipeOffset = 0
                        }
                        if triggered { onReply(message) }
                    }
                )
                .offset(x: swipeOffset)
                .background(alignment: .leading) {
                    if swipeOffset > 0 {
                        let progress = min(swipeOffset / 60.0, 1.0)
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .foregroundStyle(.tertiary)
                            .scaleEffect(0.4 + progress * 0.6)
                            .opacity(Double(progress))
                    }
                }
                .zIndex(200)
                .id("emoji-bubble-\(message.base.id)")
                .opacity(isAppearing ? 0.0 : 1.0)
                .blur(radius: isAppearing ? 10.0 : 0.0)
                .scaleEffect(isAppearing ? 0.0 : 1.0)
                .rotationEffect(
                    .radians(
                        isAppearing
                        ? (message.base.source == .incoming ? -0.10 : 0.10)
                        : 0
                    )
                )
                .offset(
                    x: isAppearing
                    ? (message.base.source == .incoming ? -200 : 200)
                    : 0,
                    y: isAppearing ? 40 : 0
                )
                .padding(.trailing, DesignConstants.Spacing.step4x)

            case .invite(let invite):
                MessageInviteContainerView(
                    invite: invite,
                    style: bubbleType,
                    isOutgoing: message.base.source == .outgoing,
                    profile: message.base.sender.profile,
                    onTapInvite: onTapInvite,
                ) {
                    onTapAvatar(message)
                }
                .zIndex(200)
                .id("message-invite-\(message.base.id)")
                .scaleEffect(isAppearing ? 0.9 : 1.0)
                .rotationEffect(
                    .radians(
                        isAppearing
                        ? (message.base.source == .incoming ? -0.05 : 0.05)
                        : 0
                    )
                )
                .offset(
                    x: isAppearing
                    ? (message.base.source == .incoming ? -20 : 20)
                    : 0,
                    y: isAppearing ? 40 : 0
                )
                .padding(.trailing, DesignConstants.Spacing.step4x)

            case .attachment(let attachment):
                attachmentView(for: attachment)

            case .attachments(let attachments):
                if let attachment = attachments.first {
                    attachmentView(for: attachment)
                }

            case .update:
                // Updates are handled at the item level, not here
                EmptyView()
            }
        }
        .id("messages-group-item-view-\(message.base.id)")
        .transition(
            .asymmetric(
                insertion: .identity,      // no transition on insert
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

    @State private var photoSwipeOffset: CGFloat = 0

    @ViewBuilder
    private func attachmentView(for attachment: HydratedAttachment) -> some View {
        AttachmentPlaceholder(
            attachment: attachment,
            isOutgoing: message.base.sender.isCurrentUser,
            profile: message.base.sender.profile,
            shouldBlurPhotos: shouldBlurPhotos,
            cornerRadius: 0,
            onReveal: { onPhotoRevealed(attachment.key) },
            onHide: { onPhotoHidden(attachment.key) },
            onDoubleTap: { onDoubleTap(message) },
            onReply: { onReply(message) },
            onDimensionsLoaded: { width, height in
                onPhotoDimensionsLoaded(attachment.key, width, height)
            }
        )
        .messageInteractions(
            message: message,
            bubbleStyle: .normal,
            onSwipeOffsetChanged: { photoSwipeOffset = $0 },
            onSwipeEnded: { triggered in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    photoSwipeOffset = 0
                }
                if triggered { onReply(message) }
            }
        )
        .offset(x: photoSwipeOffset)
        .background(alignment: .leading) {
            if photoSwipeOffset > 0 {
                let progress = min(photoSwipeOffset / 60.0, 1.0)
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .foregroundStyle(.tertiary)
                    .scaleEffect(0.4 + progress * 0.6)
                    .opacity(Double(progress))
                    .padding(.leading, DesignConstants.Spacing.step2x)
            }
        }
        .id(message.base.id)
    }
}

// MARK: - Attachment Views

private struct AttachmentPlaceholder: View {
    static let maxPhotoWidth: CGFloat = 430

    let attachment: HydratedAttachment
    let isOutgoing: Bool
    let profile: Profile
    let shouldBlurPhotos: Bool
    var cornerRadius: CGFloat = 0
    let onReveal: () -> Void
    let onHide: () -> Void
    let onDoubleTap: () -> Void
    let onReply: () -> Void
    let onDimensionsLoaded: (Int, Int) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    @State private var loadedImage: UIImage?
    @State private var isLoading: Bool = true
    @State private var loadError: Error?
    @State private var showingSaveSuccess: Bool = false
    @State private var showingSaveError: Bool = false
    @State private var isPressed: Bool = false

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
        return isPressed ? 15 : 20
    }

    private var blurOpacity: Double {
        guard showBlurOverlay else { return 1.0 }
        return isPressed ? 0.5 : 0.3
    }

    private var placeholderAspectRatio: CGFloat {
        attachment.aspectRatio ?? (4.0 / 3.0)
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                photoContent(image: image)
                    .clipShape(RoundedRectangle(cornerRadius: isRegularWidth ? DesignConstants.CornerRadius.medium : 0))
                    .frame(maxWidth: isRegularWidth ? Self.maxPhotoWidth : .infinity)
                    .frame(maxWidth: .infinity, alignment: isRegularWidth ? .center : .leading)
            } else if isLoading {
                loadingPlaceholder
            } else {
                errorPlaceholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .sensoryFeedback(.success, trigger: showingSaveSuccess)
        .sensoryFeedback(.error, trigger: showingSaveError)
        .task {
            await loadAttachment()
        }
    }

    @ViewBuilder
    private func photoContent(image: UIImage) -> some View {
        ZStack(alignment: isOutgoing ? .bottomTrailing : .topLeading) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .blur(radius: showBlurOverlay ? blurRadius : 0)
                .opacity(showBlurOverlay ? blurOpacity : 1.0)

            if showBlurOverlay {
                PhotoBlurOverlayContent()
                    .transition(.opacity)
            }

            PhotoSenderLabel(profile: profile, isOutgoing: isOutgoing)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if showBlurOverlay {
                onReveal()
            }
        }
        .animation(.easeOut(duration: 0.25), value: showBlurOverlay)
        .animation(.easeOut(duration: 0.15), value: isPressed)
    }

    private func saveToPhotoLibrary(image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    showingSaveError = true
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                Task { @MainActor in
                    if success {
                        showingSaveSuccess = true
                    } else {
                        Log.error("Failed to save photo: \(error?.localizedDescription ?? "Unknown error")")
                        showingSaveError = true
                    }
                }
            }
        }
    }

    private func loadAttachment() async {
        isLoading = true
        loadError = nil

        let cacheKey = attachment.key

        // Check ImageCache first (memory + disk with proper eviction)
        if let cachedImage = await ImageCache.shared.imageAsync(for: cacheKey) {
            loadedImage = cachedImage
            isLoading = false
            // Backfill dimensions for old photos that were cached before we tracked dims
            if attachment.width == nil {
                onDimensionsLoaded(Int(cachedImage.size.width), Int(cachedImage.size.height))
            }
            return
        }

        do {
            let imageData: Data

            if attachment.key.hasPrefix("file://"), let url = URL(string: attachment.key) {
                imageData = try Data(contentsOf: url)
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
                // Cache in ImageCache for future loads (handles disk + eviction)
                ImageCache.shared.cacheImage(image, for: cacheKey)

                // Save dimensions if not already stored (for incoming photos)
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
            .frame(maxWidth: .infinity, alignment: isRegularWidth ? .center : .leading)
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
            .frame(maxWidth: .infinity, alignment: isRegularWidth ? .center : .leading)
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
            .overlay(
                Circle()
                    .strokeBorder(Color.colorVibrantQuaternary, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

            Text(profile.displayName)
                .font(.caption)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
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
        onDoubleTap: { _ in },
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
        onDoubleTap: { _ in },
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
        onDoubleTap: { _ in },
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
        onDoubleTap: { _ in },
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
        onDoubleTap: { _ in },
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
        onDoubleTap: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in },
        onPhotoDimensionsLoaded: { _, _, _ in }
    )
    .padding()
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
        onDoubleTap: { _ in },
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
        onDoubleTap: { _ in },
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
        onDoubleTap: { _ in },
        onPhotoRevealed: { _ in print("Photo revealed") },
        onPhotoHidden: { _ in print("Photo hidden") },
        onPhotoDimensionsLoaded: { _, _, _ in }
    )
    .padding()
}
// swiftlint:enable force_unwrapping


