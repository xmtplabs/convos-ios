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
    ControlGroup {
        let togglePinAction = { viewModel.togglePin(conversation: conversation) }
        Button(action: togglePinAction) {
            Label(
                conversation.isPinned ? "Unfav" : "Fav",
                systemImage: conversation.isPinned ? "star.slash.fill" : "star.fill"
            )
        }

        let toggleReadAction = { viewModel.toggleReadState(conversation: conversation) }
        Button(action: toggleReadAction) {
            Label(
                conversation.isUnread ? "Read" : "Unread",
                systemImage: conversation.isUnread ? "checkmark.message.fill" : "message.badge.fill"
            )
        }

        let toggleMuteAction = { viewModel.toggleMute(conversation: conversation) }
        Button(action: toggleMuteAction) {
            Label(
                conversation.isMuted ? "Unmute" : "Mute",
                systemImage: conversation.isMuted ? "bell.fill" : "bell.slash.fill"
            )
        }
    }
    .accessibilityIdentifier("context-menu-pin")

    if conversation.creator.isCurrentUser {
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
