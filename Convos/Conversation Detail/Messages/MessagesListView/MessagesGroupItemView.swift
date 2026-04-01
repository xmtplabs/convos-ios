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
                .padding(.leading, !message.sender.isCurrentUser && message.content.isAttachment
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

        AttachmentPlaceholder(
            attachment: attachment,
            isOutgoing: message.sender.isCurrentUser,
            profile: message.sender.profile,
            shouldBlurPhotos: shouldBlurPhotos,
            cornerRadius: 0,
            onDimensionsLoaded: { width, height in
                onPhotoDimensionsLoaded(attachment.key, width, height)
            }
        )
        .messageGesture(
            message: message,
            bubbleStyle: .normal,
            onSingleTap: isBlurred ? { onPhotoRevealed(attachment.key) } : nil,
            onReply: onReply
        )
        .id(message.messageId)
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
    let onDimensionsLoaded: (Int, Int) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    @State private var loadedImage: UIImage?
    @State private var isLoading: Bool = true
    @State private var loadError: Error?
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

    private var blurOpacity: Double {
        1.0
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
                    .frame(maxWidth: .infinity, alignment: isRegularWidth ? (isOutgoing ? .trailing : .leading) : .leading)
                    .padding(isRegularWidth ? (isOutgoing ? .trailing : .leading) : [], DesignConstants.Spacing.step4x)
            } else if isLoading {
                loadingPlaceholder
            } else {
                errorPlaceholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
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
                .scaleEffect(showBlurOverlay ? 1.65 : 1.0)
                .blur(radius: showBlurOverlay ? blurRadius : 0)
                .opacity(showBlurOverlay ? blurOpacity : 1.0)

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
                let url = URL(fileURLWithPath: path)
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
