import SwiftUI

/// Top-right menu on a Things detail page: shares the current thing's link into
/// a composer. Mirrors `AddToConversationMenu`'s Menu-in-toolbar shape (a share
/// glyph label opening title/subtitle/icon buttons) so the toolbar builder in
/// `ConversationView` stays within the type-check budget.
///
/// The Agent row is shown only once the agent DM is bound; before that its
/// composer does not exist to receive the link.
struct ShareThingMenu: View {
    let canShareToAgent: Bool
    let onShareToGroup: () -> Void
    let onShareToAgent: () -> Void

    var body: some View {
        Menu {
            Button(action: onShareToGroup) {
                Text("Share with group")
                Image(systemName: "message")
            }
            .accessibilityIdentifier("share-thing-to-group")

            if canShareToAgent {
                Button(action: onShareToAgent) {
                    Text("Work with agent")
                    Image(systemName: "pencil")
                }
                .accessibilityIdentifier("share-thing-to-agent")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Share")
        .accessibilityIdentifier("share-thing-menu")
    }
}

#Preview {
    NavigationStack {
        Text("Accommodation")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareThingMenu(
                        canShareToAgent: true,
                        onShareToGroup: {},
                        onShareToAgent: {}
                    )
                }
            }
    }
}
