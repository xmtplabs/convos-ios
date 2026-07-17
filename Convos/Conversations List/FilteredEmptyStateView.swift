import ConvosCore
import SwiftUI

struct FilteredEmptyStateView: View {
    let message: String
    /// Spoken label for the "Show all" button. Defaults to the conversations-
    /// list phrasing; other surfaces (e.g. contacts) pass their own.
    var accessibilityLabel: String = "Show all conversations"
    let onShowAll: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.colorTextSecondary)

            let showAllAction = { onShowAll() }
            Button(action: showAllAction) {
                Text("Show all")
            }
            .convosButtonStyle(.rounded(fullWidth: false))
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("show-all-button")
        }
        .frame(maxWidth: .infinity)
        .padding(DesignConstants.Spacing.step6x)
        .background(.colorFillMinimal)
        .cornerRadius(DesignConstants.Spacing.step6x)
    }
}

#Preview {
    FilteredEmptyStateView(message: "No unread convos") {}
}
