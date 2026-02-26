import SwiftUI

struct AddToConversationMenu: View {
    let isFull: Bool
    let isEnabled: Bool
    let onNewAssistant: () -> Void
    let onConvoCode: () -> Void

    private var isAssistantEnabled: Bool { FeatureFlags.shared.isAssistantEnabled }

    private var labelColor: Color {
        if !isEnabled {
            return .colorTextSecondary.opacity(0.4)
        }
        return isFull ? .colorTextSecondary : .colorTextPrimary
    }

    var body: some View {
        if isAssistantEnabled {
            menuView
        } else {
            Button(action: onConvoCode) {
                Image(systemName: "plus")
                    .foregroundStyle(labelColor)
            }
            .disabled(!isEnabled)
            .accessibilityLabel("Add to conversation")
            .accessibilityIdentifier("add-to-conversation-button")
        }
    }

    private var menuView: some View {
        Menu {
            Section("Invite an AI member") {
                Button(action: onNewAssistant) {
                    Text("New Assistant")
                    Text("How can I help?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "triangle")
                }
                .accessibilityIdentifier("context-menu-add-assistant")

                Button {} label: {
                    Text("Outside Agent")
                    Text("Claude, OpenClaw and others")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "viewfinder")
                }
                .accessibilityIdentifier("context-menu-add-outside-agent")
                .disabled(true)
            }

            Section("Invite people") {
                Button(action: onConvoCode) {
                    Text("Convo code")
                    Text("Show or send an invitation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "qrcode")
                }
                .accessibilityIdentifier("context-menu-convo-code")
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
                        onNewAssistant: {},
                        onConvoCode: {}
                    )
                }
            }
    }
}
