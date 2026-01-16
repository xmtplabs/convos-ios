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
    let onDoubleTap: (AnyMessage) -> Void
    let onPhotoRevealed: (String) -> Void
    let onPhotoHidden: (String) -> Void

    @State private var isAppearing: Bool = true

    private var animates: Bool {
        message.origin == .inserted
    }

    var body: some View {
        VStack(alignment: message.base.sender.isCurrentUser ? .trailing : .leading, spacing: 0.0) {
            switch message.base.content {
            case .text(let text):
                MessageBubble(
                    style: message.base.content.isEmoji ? .none : bubbleType,
                    message: text,
                    isOutgoing: message.base.sender.isCurrentUser,
                    profile: message.base.sender.profile,
                )
                .zIndex(200)
                .id("bubble-\(message.base.id)")
                .onTapGesture(count: 2) {
                    onDoubleTap(message)
                }
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

            case .emoji(let text):
                EmojiBubble(
                    emoji: text,
                    isOutgoing: message.base.sender.isCurrentUser,
                    profile: message.base.sender.profile
                )
                .zIndex(200)
                .id("emoji-bubble-\(message.base.id)")
                .onTapGesture(count: 2) {
                    onDoubleTap(message)
                }
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

            case .attachment(let attachmentData):
                AttachmentPlaceholder(
                    attachmentData: attachmentData,
                    isOutgoing: message.base.sender.isCurrentUser,
                    shouldBlur: shouldBlurPhotos,
                    onReveal: { onPhotoRevealed(attachmentData) },
                    onHide: { onPhotoHidden(attachmentData) }
                )
                .id(message.base.id)
                .onTapGesture(count: 2) {
                    onDoubleTap(message)
                }

            case .attachments(let attachmentsData):
                if let firstData = attachmentsData.first {
                    AttachmentPlaceholder(
                        attachmentData: firstData,
                        isOutgoing: message.base.sender.isCurrentUser,
                        shouldBlur: shouldBlurPhotos,
                        onReveal: { onPhotoRevealed(firstData) },
                        onHide: { onPhotoHidden(firstData) }
                    )
                    .id(message.base.id)
                    .onTapGesture(count: 2) {
                        onDoubleTap(message)
                    }
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
            guard isAppearing else { return }

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
}

// MARK: - Attachment Views

private struct AttachmentPlaceholder: View {
    let attachmentData: String
    let isOutgoing: Bool
    let shouldBlur: Bool
    let onReveal: () -> Void
    let onHide: () -> Void

    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadError: Error?
    @State private var isRevealed: Bool = false
    @State private var showingSaveSuccess: Bool = false
    @State private var showingSaveError: Bool = false
    @State private var uploadStage: PhotoUploadStage?

    private static let loader = RemoteAttachmentLoader()

    private var showBlurOverlay: Bool {
        shouldBlur && !isOutgoing && !isRevealed
    }

    private var canShowContextMenu: Bool {
        loadedImage != nil && !showBlurOverlay
    }

    private var showUploadProgress: Bool {
        guard isOutgoing, let stage = uploadStage else { return false }
        return stage.isInProgress
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)

                    if showBlurOverlay {
                        PhotoBlurOverlayView(image: image) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                isRevealed = true
                            }
                            onReveal()
                        }
                    }

                    if showUploadProgress, let stage = uploadStage {
                        PhotoUploadProgressOverlay(stage: stage)
                    }
                }
            } else if isLoading {
                loadingPlaceholder
            } else {
                errorPlaceholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
        .contextMenu {
            if canShowContextMenu, let image = loadedImage {
                Button {
                    saveToPhotoLibrary(image: image)
                } label: {
                    Label("Save to Photo Library", systemImage: "square.and.arrow.down")
                }
                if isRevealed && !isOutgoing {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isRevealed = false
                        }
                        onHide()
                    } label: {
                        Label("Hide Photo", systemImage: "eye.slash")
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: showingSaveSuccess)
        .sensoryFeedback(.error, trigger: showingSaveError)
        .task {
            await loadAttachment()
        }
        .task {
            await pollUploadProgress()
        }
    }

    private func pollUploadProgress() async {
        guard isOutgoing else { return }
        while !Task.isCancelled {
            let stage = PhotoUploadProgressTracker.shared.stage(for: attachmentData)
            await MainActor.run {
                uploadStage = stage
            }
            if stage == nil || stage == .completed || stage == .failed {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
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

        let cacheKey = attachmentData

        // Check ImageCache first (memory + disk with proper eviction)
        if let cachedImage = await ImageCache.shared.imageAsync(for: cacheKey) {
            loadedImage = cachedImage
            isLoading = false
            return
        }

        do {
            let imageData: Data

            if attachmentData.hasPrefix("file://"), let url = URL(string: attachmentData) {
                imageData = try Data(contentsOf: url)
            } else if attachmentData.hasPrefix("{") {
                imageData = try await Self.loader.loadImageData(from: attachmentData)
            } else if let url = URL(string: attachmentData) {
                let (data, _) = try await URLSession.shared.data(from: url)
                imageData = data
            } else {
                throw NSError(domain: "AttachmentPlaceholder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid attachment data"])
            }

            if let image = UIImage(data: imageData) {
                loadedImage = image
                // Cache in ImageCache for future loads (handles disk + eviction)
                ImageCache.shared.cacheImage(image, for: cacheKey)
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
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
            .overlay {
                ProgressView()
            }
    }

    private var errorPlaceholder: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
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
    }
}

// MARK: - Upload Progress Overlay

private struct PhotoUploadProgressOverlay: View {
    let stage: PhotoUploadStage

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)

            VStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)

                Text(stage.label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
            }
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
        bubbleType: .normal,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onDoubleTap: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in }
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
        onDoubleTap: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in }
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
        onDoubleTap: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in }
    )
    .padding()
}

#Preview("Emoji Message") {
    MessagesGroupItemView(
        message: .message(Message.mock(
            text: "😊👍🎉",
            sender: .mock(isCurrentUser: false),
            status: .published
        ), .existing),
        bubbleType: .tailed,
        shouldBlurPhotos: false,
        onTapAvatar: { _ in },
        onTapInvite: { _ in },
        onDoubleTap: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in }
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
        onDoubleTap: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in }
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
        onDoubleTap: { _ in },
        onPhotoRevealed: { _ in },
        onPhotoHidden: { _ in }
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
        onDoubleTap: { _ in },
        onPhotoRevealed: { _ in print("Photo revealed") },
        onPhotoHidden: { _ in print("Photo hidden") }
    )
    .padding()
}
// swiftlint:enable force_unwrapping
