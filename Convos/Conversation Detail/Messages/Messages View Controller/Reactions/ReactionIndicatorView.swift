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

    @State private var appearedEmojis: Set<String> = []
    @State private var pillAppeared: Bool = false

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.stepHalf) {
            ForEach(emojis, id: \.self) { emoji in
                let appeared = appearedEmojis.contains(emoji)
                Text(emoji)
                    .font(.callout)
                    .blur(radius: appeared ? 0 : 10)
                    .scaleEffect(appeared ? 1.0 : 0)
                    .rotationEffect(.degrees(appeared ? 0 : -15))
                    .animation(.spring(response: 0.29, dampingFraction: 0.6), value: appeared)
                    .onAppear {
                        if !appearedEmojis.contains(emoji) {
                            withAnimation(.spring(response: 0.29, dampingFraction: 0.6)) {
                                _ = appearedEmojis.insert(emoji)
                            }
                        }
                    }
            }
            if count > 1 {
                Text("\(count)")
                    .font(.footnote)
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
        .scaleEffect(pillAppeared ? 1.0 : 0.5)
        .opacity(pillAppeared ? 1.0 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.29, dampingFraction: 0.7)) {
                pillAppeared = true
            }
        }
        .onChange(of: emojis) { _, newEmojis in
            let newSet = Set(newEmojis)
            let added = newSet.subtracting(appearedEmojis)
            if !added.isEmpty {
                for (index, emoji) in added.enumerated() {
                    let delay = Double(index) * 0.04
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation(.spring(response: 0.29, dampingFraction: 0.6)) {
                            _ = appearedEmojis.insert(emoji)
                        }
                    }
                }
            }
            appearedEmojis = appearedEmojis.intersection(newSet)
        }
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
