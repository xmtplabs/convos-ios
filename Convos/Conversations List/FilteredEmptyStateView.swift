import ConvosCore
import SwiftUI

struct FilteredEmptyStateView: View {
    let message: String
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
            .accessibilityLabel("Show all conversations")
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
