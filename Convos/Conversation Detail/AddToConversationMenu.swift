import SwiftUI

struct AddToConversationMenu: View {
    let isFull: Bool
    let isEnabled: Bool
    let onConvoCode: () -> Void
    let onCopyLink: () -> Void
    let onInviteAssistant: () -> Void

    private var isAssistantEnabled: Bool { FeatureFlags.shared.isAssistantEnabled }

    private var labelColor: Color {
        if !isEnabled {
            return .colorTextSecondary.opacity(0.4)
        }
        return isFull ? .colorTextSecondary : .colorTextPrimary
    }

    var body: some View {
        Menu {
            Section("Invite members") {
                Button(action: onConvoCode) {
                    Text("Convo code")
                    Text("Show, share or AirDrop it")
                    Image(systemName: "qrcode")
                }
                .accessibilityIdentifier("context-menu-convo-code")

                Button(action: onCopyLink) {
                    Text("Link")
                    Text("Copy to clipboard")
                    Image(systemName: "link")
                }
                .accessibilityIdentifier("context-menu-copy-link")

                if isAssistantEnabled {
                    Button(action: onInviteAssistant) {
                        Text("Invite an assistant")
                        Text("To help this group do things")
                        Image(systemName: "a.circle")
                    }
                    .accessibilityIdentifier("context-menu-add-assistant")
                }
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
