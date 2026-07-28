import ConvosCore
import SwiftUI

struct FilteredEmptyStateView: View {
    let message: String
    /// Spoken label for the "Show all" button. Defaults to the conversations-
    /// list phrasing; other surfaces (e.g. contacts) pass their own.
    var accessibilityLabel: String = "Show all conversations"
    let onShowAll: () -> Void

    var body: some View {
        ConvosEmptyStateCard(
            message: message,
            actionTitle: "Show all",
            actionAccessibilityLabel: accessibilityLabel,
            actionAccessibilityIdentifier: "show-all-button",
            action: onShowAll
        )
    }
}

#Preview {
    FilteredEmptyStateView(message: "No unread convos") {}
}
