import SwiftUI

/// Top-right edit menu on a Things detail page, sitting beside `ShareThingMenu`.
/// "Ask for changes" hands the thing to the agent to edit; "Edit with an app"
/// is not built yet and shows as a disabled "Soon" row.
///
/// "Ask for changes" is disabled until the agent DM is bound, since it has no
/// composer to route to before then.
struct EditThingMenu: View {
    let canAskAgent: Bool
    let onAskForChanges: () -> Void

    var body: some View {
        Menu {
            Button(action: onAskForChanges) {
                Text("Ask for changes")
                Text("Your agent will change it")
                Image(systemName: "message")
            }
            .disabled(!canAskAgent)
            .accessibilityIdentifier("edit-thing-ask-agent")

            // Disabled, so the row (icon included) renders in the faint inactive
            // style, matching the "Soon" state.
            Button(action: {}) {
                Text("Edit with an app")
                Text("Soon")
                Image(systemName: "pencil")
            }
            .disabled(true)
            .accessibilityIdentifier("edit-thing-with-app")
        } label: {
            Image(systemName: "pencil")
        }
        .accessibilityLabel("Edit")
        .accessibilityIdentifier("edit-thing-menu")
    }
}

#Preview {
    NavigationStack {
        Text("Accommodation")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EditThingMenu(canAskAgent: true, onAskForChanges: {})
                }
            }
    }
}
