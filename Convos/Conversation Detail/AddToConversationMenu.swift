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
    /// Opens the contacts picker scoped to the destination conversation.
    /// Every menu surface (chat header, info view, members list) offers
    /// this row. Pair the call site with `.addFromContactsPicker(...)` to
    /// present the picker; the closure typically just sets a `Bool` state
    /// that's bound to that modifier's `isPresented`.
    let onAddFromContacts: () -> Void

    private var isAssistantEnabled: Bool { FeatureFlags.shared.isAssistantEnabled && GlobalConvoDefaults.shared.assistantsEnabled }
    private var isAssistantActionDisabled: Bool { hasAssistant || isAssistantJoinPending }

    private var assistantSubtitle: String {
        if hasAssistant { return "Already here" }
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

            Button(action: onAddFromContacts) {
                Text("Add from Contacts")
                Text("Pick from people you've talked to")
                Image(systemName: "person.crop.circle.badge.plus")
            }
            .accessibilityIdentifier("context-menu-add-from-contacts")

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
                        onInviteAssistant: {},
                        onAddFromContacts: {}
                    )
                }
            }
    }
}
