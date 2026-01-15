import ConvosCore
import SwiftUI

@ViewBuilder
func conversationContextMenuContent(
    conversation: Conversation,
    viewModel: ConversationsViewModel,
    onDelete: @escaping () -> Void
) -> some View {
    let togglePinAction = { viewModel.togglePin(conversation: conversation) }
    Button(action: togglePinAction) {
        Label(
            conversation.isPinned ? "Unpin" : "Pin",
            systemImage: conversation.isPinned ? "pin.slash.fill" : "pin.fill"
        )
    }

    let toggleReadAction = { viewModel.toggleReadState(conversation: conversation) }
    Button(action: toggleReadAction) {
        Label(
            conversation.isUnread ? "Mark as Read" : "Mark as Unread",
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

    Divider()

    Button(role: .destructive, action: onDelete) {
        Label("Delete", systemImage: "trash")
    }
}
