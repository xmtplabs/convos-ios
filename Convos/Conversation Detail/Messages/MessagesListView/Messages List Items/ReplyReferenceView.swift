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
    var onPhotoRevealed: ((String) -> Void)?
    var onPhotoHidden: ((String) -> Void)?

    private var previewText: String {
        switch parentMessage.content {
        case .text(let text):
            return String(text.prefix(80))
        case .emoji(let emoji):
            return emoji
        default:
            return ""
        }
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

    private var shouldBlurAttachment: Bool {
        guard let parentAttachment else { return false }
        if parentMessage.sender.isCurrentUser {
            return parentAttachment.isHiddenByOwner
        }
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

            if let attachment = parentAttachment {
                ReplyReferencePhotoPreview(
                    attachmentKey: attachment.key,
                    shouldBlur: shouldBlurAttachment,
                    isOutgoing: isOutgoing,
                    onReveal: { onPhotoRevealed?(attachment.key) },
                    onHide: { onPhotoHidden?(attachment.key) }
                )
                .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step4x : 0.0)
            } else {
                Text(previewText)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .padding(.vertical, DesignConstants.Spacing.step2x)
                    .background(
                        RoundedRectangle(cornerRadius: Constant.bubbleCornerRadius)
                            .strokeBorder(.colorBorderSubtle, lineWidth: 1.0)
                    )
                    .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step4x : 0.0)
            }
        }
        .padding(.top, DesignConstants.Spacing.stepX)
        .padding(.bottom, DesignConstants.Spacing.stepX)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reply to \(parentMessage.sender.profile.displayName): \(previewText)")
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
    let shouldBlur: Bool
    let isOutgoing: Bool
    let onReveal: () -> Void
    let onHide: () -> Void

    @State private var loadedImage: UIImage?

    private static let loader: RemoteAttachmentLoader = RemoteAttachmentLoader()
    private static let maxHeight: CGFloat = 80.0

    init(attachmentKey: String, shouldBlur: Bool, isOutgoing: Bool, onReveal: @escaping () -> Void, onHide: @escaping () -> Void) {
        self.attachmentKey = attachmentKey
        self.shouldBlur = shouldBlur
        self.isOutgoing = isOutgoing
        self.onReveal = onReveal
        self.onHide = onHide
        _loadedImage = State(initialValue: ImageCache.shared.image(for: attachmentKey))
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: Self.maxHeight)
                        .blur(radius: shouldBlur ? 10 : 0)
                        .opacity(shouldBlur ? 0.4 : 1.0)

                    if shouldBlur {
                        Image(systemName: "eye.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                            .padding(DesignConstants.Spacing.step2x)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12.0))
                .contentShape(RoundedRectangle(cornerRadius: 12.0))
                .onTapGesture {
                    if shouldBlur {
                        onReveal()
                    }
                }
                .contextMenu {
                    if shouldBlur {
                        let revealAction = { onReveal() }
                        Button(action: revealAction) {
                            Label("Reveal", systemImage: "eye")
                        }
                    } else if isOutgoing {
                        let hideAction = { onHide() }
                        Button(action: hideAction) {
                            Label("Hide", systemImage: "eye.slash")
                        }
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 12.0)
                    .fill(.quaternary)
                    .frame(width: 60.0, height: Self.maxHeight)
            }
        }
        .task {
            guard loadedImage == nil else { return }
            if let cachedImage = await ImageCache.shared.imageAsync(for: attachmentKey) {
                loadedImage = cachedImage
                return
            }
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
