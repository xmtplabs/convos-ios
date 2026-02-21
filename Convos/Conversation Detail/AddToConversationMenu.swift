import SwiftUI

struct AddToConversationMenu: View {
    let isFull: Bool
    let isEnabled: Bool
    let onNewAssistant: () -> Void
    let onConvoCode: () -> Void
    var onMenuOpen: (() -> Void)?

    var body: some View {
        Menu {
            Section {
                EmptyView()
                    .onAppear { onMenuOpen?() }
            }

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
                .foregroundStyle(isFull ? .colorTextSecondary : .colorTextPrimary)
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
