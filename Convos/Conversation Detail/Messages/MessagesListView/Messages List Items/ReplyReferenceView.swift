import ConvosCore
import ConvosLogging
import SwiftUI
import UIKit

struct ReplyReferenceView: View {
    let replySender: ConversationMember
    let parentMessage: Message
    let isOutgoing: Bool
    var onTapAvatar: (() -> Void)?

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

    private var attachmentKey: String? {
        switch parentMessage.content {
        case .attachment(let attachment):
            return attachment.key
        case .attachments(let attachments):
            return attachments.first?.key
        default:
            return nil
        }
    }

    private var isPhotoReply: Bool {
        attachmentKey != nil
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

            if let key = attachmentKey {
                ReplyReferencePhotoPreview(attachmentKey: key)
            } else {
                HStack(alignment: .bottom, spacing: 0.0) {
                    if isOutgoing {
                        Spacer()
                            .frame(minWidth: 50.0)
                            .layoutPriority(-1)
                    }

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

                    if !isOutgoing {
                        Spacer()
                            .frame(minWidth: 50.0)
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
        isOutgoing: true
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
        isOutgoing: false
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
        isOutgoing: true
    )
    .padding()
}

// MARK: - Photo Preview

private struct ReplyReferencePhotoPreview: View {
    let attachmentKey: String

    @State private var loadedImage: UIImage?

    private static let loader: RemoteAttachmentLoader = RemoteAttachmentLoader()
    private static let maxHeight: CGFloat = 80.0

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: Self.maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12.0))
            } else {
                RoundedRectangle(cornerRadius: 12.0)
                    .fill(.quaternary)
                    .frame(width: 60.0, height: Self.maxHeight)
            }
        }
        .task {
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
