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
            .padding(.leading, isOutgoing ? 0.0 : DesignConstants.Spacing.step5x)
            .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step5x : 0.0)

            if let attachment = parentAttachment {
                ReplyReferencePhotoPreview(
                    attachmentKey: attachment.key,
                    shouldBlur: shouldBlurAttachment,
                    onReveal: { onPhotoRevealed?(attachment.key) },
                    onHide: { onPhotoHidden?(attachment.key) }
                )
                .padding(.leading, isOutgoing ? 0.0 : DesignConstants.Spacing.step3x)
                .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step4x : 0.0)
            } else if let emoji = parentEmoji {
                Text(emoji)
                    .font(.largeTitle)
                    .padding(.leading, isOutgoing ? 0.0 : DesignConstants.Spacing.step3x)
                    .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step4x : 0.0)
            } else if let invite = parentInvite {
                if let onTapInvite {
                    let tapAction = { onTapInvite(invite) }
                    Button(action: tapAction) {
                        ReplyReferenceInvitePreview(invite: invite)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, isOutgoing ? 0.0 : DesignConstants.Spacing.step3x)
                    .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step4x : 0.0)
                } else {
                    ReplyReferenceInvitePreview(invite: invite)
                        .padding(.leading, isOutgoing ? 0.0 : DesignConstants.Spacing.step3x)
                        .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step4x : 0.0)
                }
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
                .padding(.leading, isOutgoing ? 0.0 : DesignConstants.Spacing.step3x)
                .padding(.trailing, isOutgoing ? DesignConstants.Spacing.step4x : 0.0)
            }
        }
        .padding(.top, DesignConstants.Spacing.stepX)
        .padding(.bottom, DesignConstants.Spacing.stepX)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reply to \(parentMessage.sender.profile.displayName): \(previewText)")
    }

    private var replyTextPreview: some View {
        Text(previewText)
            .font(.footnote)
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
    let shouldBlur: Bool
    let onReveal: () -> Void
    let onHide: () -> Void

    @State private var loadedImage: UIImage?

    private static let loader: RemoteAttachmentLoader = RemoteAttachmentLoader()
    private static let maxHeight: CGFloat = 80.0

    init(attachmentKey: String, shouldBlur: Bool, onReveal: @escaping () -> Void, onHide: @escaping () -> Void) {
        self.attachmentKey = attachmentKey
        self.shouldBlur = shouldBlur
        self.onReveal = onReveal
        self.onHide = onHide
        _loadedImage = State(initialValue: ImageCache.shared.image(for: attachmentKey))
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: Self.maxHeight)
                    .blur(radius: shouldBlur ? 10 : 0)
                    .opacity(shouldBlur ? 0.4 : 1.0)
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
                        } else {
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

// MARK: - Invite Preview

private struct ReplyReferenceInvitePreview: View {
    let invite: MessageInvite
    @State private var cachedImage: UIImage?

    private var title: String {
        if let name = invite.conversationName, !name.isEmpty {
            return "Pop into my convo \"\(name)\""
        }
        return "Pop into my convo before it explodes"
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
                    Image("convosIconLarge")
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
            .background(.colorBackgroundInverted)

            VStack(alignment: .leading, spacing: 1.0) {
                Text(title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.black)
                    .font(.caption.weight(.bold))
                    .truncationMode(.tail)
                Text(description)
                    .font(.caption2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.vertical, DesignConstants.Spacing.step2x)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 210.0, alignment: .leading)
        .background(.colorLinkBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10.0))
        .cachedImage(for: invite) { image in
            cachedImage = image
        }
    }
}
