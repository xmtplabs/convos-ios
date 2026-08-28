import ConvosCore
import SwiftUI

/// Asks which variant the conversation about to be created should build its
/// agent under. Presented from the compose entry point while
/// `FeatureFlags.isAgentVariantSelectorEnabled` is on, ahead of the
/// new-conversation flow.
///
/// The pick is handed to the caller, which passes it to the creation flow so it
/// binds to that specific conversation once it has an id. Starts on the last
/// variant chosen in the make-an-agent composer, so the common case is
/// Continue without touching the dropdown.
struct AgentVariantPickerSheet: View {
    let onContinue: (String?) -> Void

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
            // The persisted default may name a variant that has since been
            // retired -- `loadIfNeeded` clears it from FeatureFlags during
            // reconciliation, so drop it here too rather than handing a dead
            // slug to the new conversation. Validated against the live list so
            // a pick made while the fetch was in flight survives.
            if registry.loadState == .loaded, registry.variant(withSlug: selectedSlug) == nil {
                selectedSlug = nil
            }
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
            let slug = selectedSlug
            Log.info("AgentVariant: new conversation starting under variant \(slug ?? "none")")
            dismiss()
            onContinue(slug)
        }
        return Button(action: confirm) {
            Text("Continue")
        }
        .convosButtonStyle(.rounded(fullWidth: true))
    }
}
