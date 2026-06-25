import ConvosCore
import SwiftUI

struct AddToConversationMenu: View {
    let isFull: Bool
    var isAgentJoinPending: Bool = false
    let isEnabled: Bool
    let onConvoCode: () -> Void
    let onInviteAgent: () -> Void
    /// Opens the contacts picker scoped to the destination conversation.
    /// Every menu surface (chat header, info view, members list) offers
    /// this row. Pair the call site with `.addFromContactsPicker(...)` to
    /// present the picker; the closure typically just sets a `Bool` state
    /// that's bound to that modifier's `isPresented`.
    let onAddFromContacts: () -> Void

    private var isAgentActionDisabled: Bool { isAgentJoinPending }

    private var agentSubtitle: String {
        if isAgentJoinPending { return "Joining…" }
        return "Made for this group"
    }

    private var labelColor: Color {
        if !isEnabled {
            return .colorTextSecondary.opacity(0.4)
        }
        return isFull ? .colorTextSecondary : .colorTextPrimary
    }

    var body: some View {
        Menu {
            Button(action: onConvoCode) {
                Text("Invite Friends")
                Text("Show or share invite link")
                Image(systemName: "qrcode")
            }
            .accessibilityIdentifier("context-menu-convo-code")

            Button(action: onAddFromContacts) {
                Text("Add from Contacts")
                Text("People and agents")
                Image(systemName: "person.crop.circle.badge.plus")
            }
            .accessibilityIdentifier("context-menu-add-from-contacts")

            Button(action: onInviteAgent) {
                Text("New Agent")
                Text(agentSubtitle)
                Image("addAgentIcon")
                    .renderingMode(.template)
            }
            .disabled(isAgentActionDisabled)
            .accessibilityIdentifier("context-menu-add-agent")
        } label: {
            Image(systemName: "person.crop.circle.badge.plus")
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
                        onInviteAgent: {},
                        onAddFromContacts: {}
                    )
                }
            }
    }
}
