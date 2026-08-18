import ConvosCore
import SwiftUI

/// Asks which variant the conversation about to be created should build its
/// agent under. Presented from the compose entry point while
/// `FeatureFlags.isAgentVariantSelectorEnabled` is on, ahead of the
/// new-conversation flow.
///
/// The pick is written to `AgentVariantAssignmentStore.pendingSlug`; the
/// conversation claims it on its first agent join and keeps it from then on.
/// Starts on the Debug default so the common case is Continue without touching
/// the dropdown.
struct AgentVariantPickerSheet: View {
    let onContinue: () -> Void

    @State private var registry: AgentVariantRegistry = .shared
    @State private var selectedSlug: String?
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Agent variant")
                .font(.headline)
            Text("The agent in this conversation builds under the variant you pick here.")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
            variantMenu
            whatToTest
            continueButton
        }
        .padding(DesignConstants.Spacing.step4x)
        .task {
            selectedSlug = FeatureFlags.shared.selectedAgentVariant?.slug
            await registry.loadIfNeeded()
        }
    }

    private var variantMenu: some View {
        Picker("Variant", selection: $selectedSlug) {
            Text(noVariantTitle).tag(String?.none)
            ForEach(registry.variants) { variant in
                Text(variant.label).tag(String?.some(variant.slug))
            }
        }
        .pickerStyle(.menu)
        .disabled(registry.loadState == .loading)
    }

    private var noVariantTitle: String {
        registry.loadState == .loading ? "Loading variants..." : "No variant"
    }

    @ViewBuilder
    private var whatToTest: some View {
        let selected: ConvosAPI.AgentVariant? = registry.variant(withSlug: selectedSlug)
        if let selected, !selected.whatToTest.isEmpty {
            Text(selected.whatToTest)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
    }

    private var continueButton: some View {
        let confirm: () -> Void = {
            AgentVariantAssignmentStore.shared.pendingSlug = selectedSlug
            Log.info("AgentVariant: pending pick for next conversation: \(selectedSlug ?? "none")")
            dismiss()
            onContinue()
        }
        return Button(action: confirm) {
            Text("Continue")
        }
        .convosButtonStyle(.rounded(fullWidth: true))
    }
}
