import ConvosCore
import SwiftUI

/// Shown on the Agents tab when the on-device relay store could not be opened
/// at launch (a disk or Keychain failure). The tab exists because the feature
/// flag is on, so it says what is true rather than rendering an empty list
/// that looks like "no agents yet".
struct AgentsUnavailableView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Text("Relay is unavailable")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            Text("Convos could not open its agent storage on this iPhone. Restarting the app usually clears it.")
                .font(.callout)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DesignConstants.Spacing.step6x)
        .background(.colorBackgroundRaisedSecondary)
        .accessibilityIdentifier("agents-unavailable")
    }
}

#Preview {
    AgentsUnavailableView()
}
