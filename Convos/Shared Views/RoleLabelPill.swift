import ConvosCore
import SwiftUI

/// Small capsule pill rendering a short role label - "Agent",
/// "Verified by ...", "Creator", "Admin", or "You". Shared by the
/// conversation members list, the contacts list row, and the contact
/// card so every surface that tags an identity uses one styling.
struct RoleLabelPill: View {
    let label: String
    var accessibilityIdentifier: String?

    var body: some View {
        ConvosBadge(label: label)
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

#Preview {
    VStack(spacing: DesignConstants.Spacing.step2x) {
        RoleLabelPill(label: "Agent")
        RoleLabelPill(label: "Verified by Calendar")
        RoleLabelPill(label: "Creator")
        RoleLabelPill(label: "You")
    }
    .padding()
}
