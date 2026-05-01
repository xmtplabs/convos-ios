import ConvosCore
import SwiftUI

struct ReactionsDrawerView: View {
    let message: AnyMessage
    let onRemoveReaction: ((MessageReaction) -> Void)?

    init(message: AnyMessage, onRemoveReaction: ((MessageReaction) -> Void)? = nil) {
        self.message = message
        self.onRemoveReaction = onRemoveReaction
    }

    private var sortedReactions: [MessageReaction] {
        message.reactions.sorted { first, second in
            if first.sender.isCurrentUser && !second.sender.isCurrentUser {
                return true
            }
            if !first.sender.isCurrentUser && second.sender.isCurrentUser {
                return false
            }
            return first.date > second.date
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Reactions")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
                .padding(.bottom, DesignConstants.Spacing.step2x)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
                    ForEach(sortedReactions, id: \.id) { reaction in
                        ReactionRowView(
                            reaction: reaction,
                            onRemove: reaction.sender.isCurrentUser ? { onRemoveReaction?(reaction) } : nil
                        )
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicatorsFlash(onAppear: true)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: 600)
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .padding(.bottom, DesignConstants.Spacing.step3x)
    }
}

private struct ReactionRowView: View {
    let reaction: MessageReaction
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            ProfileAvatarView(
                profile: reaction.sender.profile,
                profileImage: nil,
                useSystemPlaceholder: false
            )
            .frame(width: 40.0, height: 40.0)

            VStack(alignment: .leading, spacing: 2) {
                if reaction.sender.isCurrentUser {
                    Text("You")
                        .font(.callout)
                        .foregroundStyle(.colorTextPrimary)
                    Text("Tap to remove")
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                } else {
                    Text(reaction.sender.profile.displayName.capitalized)
                        .font(.callout)
                        .foregroundStyle(.colorTextPrimary)
                }
            }

            Spacer()

            Text(reaction.emoji)
                .font(.title2)
                .padding(.trailing, DesignConstants.Spacing.step2x)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onRemove?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(reactionRowAccessibilityLabel)
        .accessibilityHint(onRemove != nil ? "Tap to remove your reaction" : "")
    }

    private var reactionRowAccessibilityLabel: String {
        let name = reaction.sender.isCurrentUser ? "You" : reaction.sender.profile.displayName
        return "\(name) reacted with \(reaction.emoji)"
    }
}

#Preview {
    @Previewable @State var presentingReactions: Bool = false

    let reactions = [
        MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: true)),
        MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: false, name: "Shane")),
        MessageReaction.mock(emoji: "😂", sender: .mock(isCurrentUser: false, name: "Jarod")),
        MessageReaction.mock(emoji: "👍", sender: .mock(isCurrentUser: false, name: "Andrew")),
        MessageReaction.mock(emoji: "🤔", sender: .mock(isCurrentUser: false, name: "Louis")),
        MessageReaction.mock(emoji: "😮", sender: .mock(isCurrentUser: false, name: "Alex")),
        MessageReaction.mock(emoji: "👎", sender: .mock(isCurrentUser: false, name: "Chris")),
        MessageReaction.mock(emoji: "🔥", sender: .mock(isCurrentUser: false, name: "Taylor")),
        MessageReaction.mock(emoji: "💯", sender: .mock(isCurrentUser: false, name: "Jordan")),
        MessageReaction.mock(emoji: "🎉", sender: .mock(isCurrentUser: false, name: "Sam")),
        MessageReaction.mock(emoji: "😍", sender: .mock(isCurrentUser: false, name: "Morgan")),
        MessageReaction.mock(emoji: "🙏", sender: .mock(isCurrentUser: false, name: "Riley")),
        MessageReaction.mock(emoji: "✨", sender: .mock(isCurrentUser: false, name: "Casey")),
        MessageReaction.mock(emoji: "💀", sender: .mock(isCurrentUser: false, name: "Quinn")),
        MessageReaction.mock(emoji: "🫡", sender: .mock(isCurrentUser: false, name: "Drew")),
    ]
    let message = Message.mock(reactions: reactions)
    let anyMessage = AnyMessage.message(message, .existing)

    VStack {
        let action = { presentingReactions.toggle() }
        Button(action: action) {
            Text("Toggle")
        }
    }
    .selfSizingSheet(isPresented: $presentingReactions) {
        ReactionsDrawerView(message: anyMessage) { _ in
        }
    }
}
