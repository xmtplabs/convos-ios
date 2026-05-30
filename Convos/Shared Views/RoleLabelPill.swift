import SwiftUI

/// Compact role/label capsule used in member rows, contact cards, picker
/// rows, and any other surface that needs to tag content with a short
/// secondary-color label ("Agent", "Creator", "Admin", "You", etc.).
///
/// Callers that need an accessibility identifier apply it as a downstream
/// modifier (e.g. `RoleLabelPill(label: "You").accessibilityIdentifier(...)`)
/// rather than baking it into the type.
struct RoleLabelPill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.footnote)
            .foregroundStyle(.colorTextSecondary)
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .padding(.vertical, DesignConstants.Spacing.stepX)
            .background(.colorTextSecondary.opacity(0.1), in: .capsule)
    }
}

#Preview("Common labels") {
    VStack(spacing: DesignConstants.Spacing.step3x) {
        RoleLabelPill(label: "Agent")
        RoleLabelPill(label: "Creator")
        RoleLabelPill(label: "Admin")
        RoleLabelPill(label: "You")
    }
    .padding()
}
