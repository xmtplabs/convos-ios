import ConvosCore
import SwiftUI

struct ReactionIndicatorView: View {
    let reactions: [MessageReaction]
    let isOutgoing: Bool
    let onTap: () -> Void

    private var uniqueEmojis: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for reaction in reactions where !seen.contains(reaction.emoji) {
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
        if reactions.isEmpty {
            EmptyView()
        } else {
            let tapAction = { onTap() }
            Button(action: tapAction) {
                ReactionPillView(
                    emojis: uniqueEmojis,
                    count: totalCount,
                    isSelected: currentUserHasReacted
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        }
    }
}

private struct ReactionPillView: View {
    let emojis: [String]
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepHalf) {
            ForEach(emojis, id: \.self) { emoji in
                Text(emoji)
                    .font(.system(size: 16))
            }
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 14))
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(isSelected ? .colorFillMinimal : .clear)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(.colorBorderSubtle, lineWidth: isSelected ? 0 : 1)
        )
    }
}

#Preview("Not Selected (outline)") {
    let reactions = [
        MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: false, name: "Alice")),
        MessageReaction.mock(emoji: "🧠", sender: .mock(isCurrentUser: false, name: "Bob")),
        MessageReaction.mock(emoji: "😜", sender: .mock(isCurrentUser: false, name: "Charlie")),
    ]

    ReactionIndicatorView(
        reactions: reactions,
        isOutgoing: false,
        onTap: {}
    )
    .padding()
}

#Preview("Selected (filled)") {
    let reactions = [
        MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: true)),
        MessageReaction.mock(emoji: "🧠", sender: .mock(isCurrentUser: false, name: "Bob")),
        MessageReaction.mock(emoji: "😜", sender: .mock(isCurrentUser: false, name: "Charlie")),
    ]

    ReactionIndicatorView(
        reactions: reactions,
        isOutgoing: false,
        onTap: {}
    )
    .padding()
}

#Preview("Mixed - Some Selected") {
    let reactions = [
        MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: false, name: "Alice")),
        MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: false, name: "Bob")),
        MessageReaction.mock(emoji: "😂", sender: .mock(isCurrentUser: true)),
    ]

    ReactionIndicatorView(
        reactions: reactions,
        isOutgoing: false,
        onTap: {}
    )
    .padding()
}
