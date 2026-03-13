import ConvosCore
import SwiftUI

struct AddToConversationMenu: View {
    let isFull: Bool
    var hasAssistant: Bool = false
    var isAssistantJoinPending: Bool = false
    let isEnabled: Bool
    let onConvoCode: () -> Void
    let onCopyLink: () -> Void
    let onInviteAssistant: () -> Void

    private var isAssistantEnabled: Bool { FeatureFlags.shared.isAssistantEnabled && GlobalConvoDefaults.shared.assistantsEnabled }
    private var isAssistantActionDisabled: Bool { hasAssistant || isAssistantJoinPending }

    private var assistantSubtitle: String {
        if hasAssistant { return "Already in conversation" }
        if isAssistantJoinPending { return "Joining…" }
        return "Helps the group do things"
    }

    private var labelColor: Color {
        if !isEnabled {
            return .colorTextSecondary.opacity(0.4)
        }
        return isFull ? .colorTextSecondary : .colorTextPrimary
    }

    var body: some View {
        Menu {
            Button(action: onCopyLink) {
                Text("Invite link")
                Text("Copy to clipboard")
                Image(systemName: "link")
            }
            .accessibilityIdentifier("context-menu-copy-link")

            Button(action: onConvoCode) {
                Text("Convo code")
                Text("Show, share or AirDrop it")
                Image(systemName: "qrcode")
            }
            .accessibilityIdentifier("context-menu-convo-code")

            if isAssistantEnabled {
                Button(action: onInviteAssistant) {
                    Text("Instant assistant")
                    Text(assistantSubtitle)
                    Image(systemName: "a.circle")
                }
                .disabled(isAssistantActionDisabled)
                .accessibilityIdentifier("context-menu-add-assistant")
            }
        } label: {
            Image(systemName: "plus")
                .foregroundStyle(labelColor)
        }
        .disabled(!isEnabled)
        .accessibilityLabel("Add to conversation")
        .accessibilityIdentifier("add-to-conversation-button")
    }
}

#Preview {
    NavigationStack {
        Text("Conversation")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AddToConversationMenu(
                        isFull: false,
                        isEnabled: true,
                        onConvoCode: {},
                        onCopyLink: {},
                        onInviteAssistant: {}
                    )
                }
            }
    }
}
