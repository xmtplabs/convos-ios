import ConvosCore
import SwiftUI

struct AddToConversationMenu: View {
    let isFull: Bool
    var hasAgent: Bool = false
    var isAgentJoinPending: Bool = false
    let isEnabled: Bool
    let onConvoCode: () -> Void
    let onCopyLink: () -> Void
    let onInviteAgent: () -> Void
    /// Opens the contacts picker scoped to the destination conversation.
    /// Every menu surface (chat header, info view, members list) offers
    /// this row. Pair the call site with `.addFromContactsPicker(...)` to
    /// present the picker; the closure typically just sets a `Bool` state
    /// that's bound to that modifier's `isPresented`.
    let onAddFromContacts: () -> Void

    private var isAgentActionDisabled: Bool { hasAgent || isAgentJoinPending }

    private var agentSubtitle: String {
        if hasAgent { return "Already here" }
        if isAgentJoinPending { return "Joining…" }
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

            Button(action: onAddFromContacts) {
                Text("Add from Contacts")
                Text("Pick from people you've talked to")
                Image(systemName: "person.crop.circle.badge.plus")
            }
            .accessibilityIdentifier("context-menu-add-from-contacts")

            Button(action: onInviteAgent) {
                Text("Instant agent")
                Text(agentSubtitle)
                Image(systemName: "a.circle")
            }
            .disabled(isAgentActionDisabled)
            .accessibilityIdentifier("context-menu-add-agent")
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
                        onInviteAgent: {},
                        onAddFromContacts: {}
                    )
                }
            }
    }
}
