import ConvosCore
import SwiftUI

@MainActor
@ViewBuilder
func conversationContextMenuContent(
    conversation: Conversation,
    viewModel: ConversationsViewModel,
    onExplode: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    let isPending = conversation.isPendingInvite

    if !isPending && conversation.hasHadVerifiedAgent {
        ControlGroup {
            let openAgentDmAction = { viewModel.selectAgentDm(conversation) }
            Button(action: openAgentDmAction) {
                Label("Agent", systemImage: "a.circle")
            }
            .accessibilityIdentifier("context-menu-open-agent-dm")

            let openThingsAction = { viewModel.selectThings(conversation) }
            Button(action: openThingsAction) {
                Label("Things", systemImage: "square.grid.2x2")
            }
            .accessibilityIdentifier("context-menu-open-things")
        }
    }

    if !isPending {
        ControlGroup {
            let togglePinAction = { viewModel.togglePin(conversation: conversation) }
            Button(action: togglePinAction) {
                Label(
                    conversation.isPinned ? "Unfav" : "Fav",
                    systemImage: conversation.isPinned ? "star.slash" : "star"
                )
            }

            let toggleReadAction = { viewModel.toggleReadState(conversation: conversation) }
            Button(action: toggleReadAction) {
                Label(
                    conversation.isUnread ? "Read" : "Unread",
                    systemImage: conversation.isUnread ? "checkmark.message" : "message.badge"
                )
            }

            let toggleMuteAction = { viewModel.toggleMute(conversation: conversation) }
            Button(action: toggleMuteAction) {
                Label(
                    conversation.isMuted ? "Unmute" : "Mute",
                    systemImage: conversation.isMuted ? "bell" : "bell.slash"
                )
            }
        }
        .accessibilityIdentifier("context-menu-pin")
    }

    if !isPending && conversation.creator.isCurrentUser {
        Button(action: onExplode) {
            Text("Explode")
            Text("For everyone")
            Image(systemName: "burst")
        }
        .accessibilityIdentifier("context-menu-explode")
    }

    Button(role: .destructive, action: onDelete) {
        Text("Delete")
        Text("For me")
        Image(systemName: "trash")
    }
    .accessibilityIdentifier("context-menu-delete")
}
