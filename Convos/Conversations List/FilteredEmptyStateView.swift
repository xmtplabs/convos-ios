import ConvosCore
import SwiftUI

struct FilteredEmptyStateView: View {
    let message: String
    let onShowAll: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Text(message)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            let showAllAction = { onShowAll() }
            Button(action: showAllAction) {
                Text("Show all")
            }
            .convosButtonStyle(.rounded(fullWidth: false))
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
