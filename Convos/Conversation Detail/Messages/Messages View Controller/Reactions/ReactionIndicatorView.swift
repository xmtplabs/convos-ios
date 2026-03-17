import ConvosCore
import SwiftUI

struct ReactionIndicatorView: View {
    let reactions: [MessageReaction]
    let isOutgoing: Bool
    let onTap: () -> Void

    private var uniqueEmojis: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for reaction in reactions.sorted(by: { $0.date > $1.date }) where !seen.contains(reaction.emoji) {
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

    private var reactionAccessibilityLabel: String {
        let emojiList = uniqueEmojis.joined(separator: ", ")
        let countText = totalCount == 1 ? "1 reaction" : "\(totalCount) reactions"
        return "\(countText): \(emojiList)"
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
                    isSelected: currentUserHasReacted,
                    maxWidth: UIScreen.main.bounds.width * Constant.maxWidth * 0.5 - 20
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(reactionAccessibilityLabel)
            .accessibilityHint("Tap to view reactions")
        }
    }
}

private struct ReactionPillView: View {
    let emojis: [String]
    let count: Int
    let isSelected: Bool
    let maxWidth: CGFloat

    @State private var appearedEmojis: Set<String> = []
    @State private var pillAppeared: Bool = false
    @State private var contentWidth: CGFloat = 0

    private var emojisOnly: some View {
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
        }
    }

    private var emojiContent: some View {
        HStack(spacing: DesignConstants.Spacing.stepHalf) {
            emojisOnly
            if count > 1 {
                Text("\(count)")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step3x)
    }

    private var needsScrolling: Bool {
        contentWidth > maxWidth
    }

    @State private var countBadgeWidth: CGFloat = 0

    var body: some View {
        Group {
            if needsScrolling {
                ZStack(alignment: .trailing) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        emojisOnly
                            .padding(.horizontal, DesignConstants.Spacing.step3x)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .contentMargins(.trailing, countBadgeWidth, for: .scrollContent)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle().fill(.black)
                            LinearGradient(
                                colors: [.black, .black.opacity(0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 12)
                            Rectangle().fill(.clear)
                                .frame(width: countBadgeWidth)
                        }
                    )

                    Text("\(count)")
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .padding(.leading, DesignConstants.Spacing.stepX)
                        .padding(.trailing, DesignConstants.Spacing.step3x)
                        .fixedSize()
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: CountBadgeWidthKey.self, value: geo.size.width)
                        })
                        .onPreferenceChange(CountBadgeWidthKey.self) { width in
                            countBadgeWidth = width
                        }
                }
                .frame(width: maxWidth)
            } else {
                emojiContent
            }
        }
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(
            emojiContent
                .fixedSize()
                .hidden()
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ContentWidthKey.self, value: geo.size.width)
                })
        )
        .onPreferenceChange(ContentWidthKey.self) { width in
            contentWidth = width + DesignConstants.Spacing.step2x * 2
        }
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

private struct ContentWidthKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CountBadgeWidthKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
