import ConvosCore
import SwiftUI

extension Conversation {
    var title: String {
        switch kind {
        case .dm:
            return otherMember?.profile.displayName ?? ""
        case .group:
            return displayName
        }
    }
}

struct ListItemView<LeadingContent: View, SubtitleContent: View, AccessoryContent: View>: View {
    let title: String
    let isMuted: Bool
    let isUnread: Bool
    @ViewBuilder let leadingContent: () -> LeadingContent
    @ViewBuilder let subtitle: () -> SubtitleContent
    @ViewBuilder let accessoryContent: () -> AccessoryContent

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            leadingContent()
                .frame(width: 56.0, height: 56.0)

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text(title)
                    .font(isUnread ? .body.weight(.medium) : .body)
                    .foregroundStyle(.colorTextPrimary)
                    .truncationMode(.tail)
                    .lineLimit(1)

                subtitle()
                    .font(.callout)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.callout)
                    .foregroundStyle(.colorFillTertiary)
            }

            if isUnread {
                Circle()
                    .fill(Color.primary)
                    .frame(width: 16, height: 16)
            }

            accessoryContent()
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConversationsListItem: View {
    let conversation: Conversation

    // Extract computed values to prevent unnecessary recalculations
    private var title: String { conversation.title }
    private var isMuted: Bool { conversation.isMuted }
    private var isUnread: Bool { conversation.isUnread }
    private var lastMessage: MessagePreview? { conversation.lastMessage }
    private var createdAt: Date { conversation.createdAt }

    var body: some View {
        ListItemView(
            title: title,
            isMuted: isMuted,
            isUnread: isUnread,
            leadingContent: {
                ConversationAvatarView(conversation: conversation, conversationImage: nil)
            },
            subtitle: {
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    if let message = lastMessage {
                        RelativeDateLabel(date: message.createdAt)
                        Text("·").foregroundStyle(.colorTextTertiary)
                        Text(message.text)
                    } else {
                        RelativeDateLabel(date: createdAt)
                    }
                }
            },
            accessoryContent: {}
        )
    }
}

#Preview {
    ConversationsListItem(conversation: .mock())
}
