import ConvosCore
import SwiftUI

struct AddToConversationMenu: View {
    let isFull: Bool
    let isEnabled: Bool
    let onConvoCode: () -> Void
    /// Opens the contacts picker scoped to the destination conversation.
    /// Every menu surface (chat header, info view, members list) offers
    /// this row. Pair the call site with `.addFromContactsPicker(...)` to
    /// present the picker; the closure typically just sets a `Bool` state
    /// that's bound to that modifier's `isPresented`.
    let onAddFromContacts: () -> Void

    private var labelColor: Color {
        if !isEnabled {
            return .colorTextSecondary.opacity(0.4)
        }
        return isFull ? .colorTextSecondary : .colorTextPrimary
    }

    var body: some View {
        Menu {
            Button(action: onAddFromContacts) {
                Text("Contacts")
                Text("People on convos")
                Image(systemName: "person.crop.circle.badge.plus")
            }
            .accessibilityIdentifier("context-menu-add-from-contacts")

            Button(action: onConvoCode) {
                Text("Invite friends")
                Text("Link, Airdrop or QR Code")
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityIdentifier("context-menu-convo-code")
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
                        onAddFromContacts: {}
                    )
                }
            }
    }
}
