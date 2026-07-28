import SwiftUI

struct ConvosEmptyStateCard: View {
    let message: String
    let actionTitle: String
    var actionAccessibilityLabel: String?
    var actionAccessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Text(message)
                .convosTextStyle(.callout)
                .multilineTextAlignment(.center)

            let buttonAction = { action() }
            Button(action: buttonAction) {
                Text(actionTitle)
            }
            .convosButtonStyle(.rounded(fullWidth: false))
            .accessibilityLabel(actionAccessibilityLabel ?? actionTitle)
            .accessibilityIdentifier(actionAccessibilityIdentifier ?? "")
        }
        .frame(maxWidth: .infinity)
        .convosSurface(.emptyState, padding: DesignConstants.Spacing.step6x)
    }
}

#Preview {
    ConvosEmptyStateCard(
        message: "No unread convos",
        actionTitle: "Show all"
    ) {}
    .padding()
}
