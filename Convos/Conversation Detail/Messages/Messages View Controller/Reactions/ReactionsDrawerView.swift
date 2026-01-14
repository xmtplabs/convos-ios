import ConvosCore
import SwiftUI

struct ReactionsDrawerView: View {
    let message: AnyMessage
    @Environment(\.dismiss) private var dismiss: DismissAction

    private var groupedReactions: [(emoji: String, senders: [ConversationMember])] {
        var groups: [String: [ConversationMember]] = [:]
        for reaction in message.base.reactions {
            groups[reaction.emoji, default: []].append(reaction.sender)
        }
        return groups.map { (emoji: $0.key, senders: $0.value) }
            .sorted { $0.senders.count > $1.senders.count }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedReactions, id: \.emoji) { group in
                    Section {
                        ForEach(group.senders, id: \.id) { sender in
                            HStack(spacing: DesignConstants.Spacing.step3x) {
                                ProfileAvatarView(
                                    profile: sender.profile,
                                    profileImage: nil,
                                    useSystemPlaceholder: false
                                )
                                .frame(width: 40.0, height: 40.0)

                                if sender.isCurrentUser {
                                    Text("You")
                                        .font(.body)
                                        .foregroundStyle(.colorTextPrimary)
                                } else {
                                    Text(sender.profile.displayName.capitalized)
                                        .font(.body)
                                        .foregroundStyle(.colorTextPrimary)
                                }

                                Spacer()
                            }
                            .padding(.vertical, DesignConstants.Spacing.stepX)
                        }
                    } header: {
                        HStack(spacing: DesignConstants.Spacing.stepX) {
                            Text(group.emoji)
                                .font(.title2)
                            Text("\(group.senders.count)")
                                .font(.headline)
                                .foregroundStyle(.colorTextSecondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    let action = { dismiss() }
                    Button(action: action) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.colorTextSecondary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    let reactions = [
        MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: false, name: "Alice")),
        MessageReaction.mock(emoji: "❤️", sender: .mock(isCurrentUser: false, name: "Bob")),
        MessageReaction.mock(emoji: "😂", sender: .mock(isCurrentUser: true)),
        MessageReaction.mock(emoji: "👍", sender: .mock(isCurrentUser: false, name: "Charlie")),
    ]
    let message = Message.mock(reactions: reactions)
    let anyMessage = AnyMessage.message(message, .existing)

    ReactionsDrawerView(message: anyMessage)
}
