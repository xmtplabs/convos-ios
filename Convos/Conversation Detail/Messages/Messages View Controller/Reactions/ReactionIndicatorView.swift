import ConvosCore
import SwiftUI

private struct ReactionGroup {
    let emoji: String
    let count: Int
    let senders: [ConversationMember]
}

struct ReactionIndicatorView: View {
    let reactions: [MessageReaction]
    let isOutgoing: Bool
    let onTap: () -> Void

    private var groupedReactions: [ReactionGroup] {
        var groups: [String: [ConversationMember]] = [:]
        for reaction in reactions {
            groups[reaction.emoji, default: []].append(reaction.sender)
        }
        return groups.map { ReactionGroup(emoji: $0.key, count: $0.value.count, senders: $0.value) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        if reactions.isEmpty {
            EmptyView()
        } else {
            let tapAction = { onTap() }
            Button(action: tapAction) {
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    ForEach(groupedReactions, id: \.emoji) { group in
                        ReactionPillView(emoji: group.emoji, count: group.count)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ReactionPillView: View {
    let emoji: String
    let count: Int

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepHalf) {
            Text(emoji)
                .font(.system(size: 14))
            if count > 1 {
                Text("\(count)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
        .padding(.vertical, DesignConstants.Spacing.stepX)
        .background(.colorBackgroundSubtle)
        .clipShape(Capsule())
    }
}

#Preview("Single Reaction") {
    let reaction = MessageReaction.mock(emoji: "❤️")

    VStack(spacing: 20) {
        ReactionIndicatorView(
            reactions: [reaction],
            isOutgoing: false,
            onTap: {}
        )

        ReactionIndicatorView(
            reactions: [reaction],
            isOutgoing: true,
            onTap: {}
        )
    }
    .padding()
}

#Preview("Multiple Reactions") {
    let reactions = [
        MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: false, name: "Alice")),
        MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: false, name: "Bob")),
        MessageReaction.mock(emoji: "😂", sender: .mock(isCurrentUser: true)),
    ]

    VStack(spacing: 20) {
        ReactionIndicatorView(
            reactions: reactions,
            isOutgoing: false,
            onTap: {}
        )

        ReactionIndicatorView(
            reactions: reactions,
            isOutgoing: true,
            onTap: {}
        )
    }
    .padding()
}
