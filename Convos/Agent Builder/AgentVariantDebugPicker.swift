import ConvosCore
import SwiftUI

/// Form-native variant picker for App Settings -> Debug, shown under the
/// "Agent variant selector" toggle. Sets the default variant new conversations
/// start from; the per-conversation picker at creation can override it.
///
/// Reads `AgentVariantRegistry.shared` rather than fetching itself -- a
/// view-scoped fetch here is cancelled and restarted by Form row churn and
/// never settles.
struct AgentVariantDebugPicker: View {
    @State private var registry: AgentVariantRegistry = .shared

    var body: some View {
        Group {
            picker
            statusRow
        }
        .task { await registry.loadIfNeeded() }
    }

    /// Always rendered, so the row structure stays stable across load states
    /// and the enclosing Form does not recreate this view mid-fetch.
    private var picker: some View {
        Picker("Variant", selection: selectionBinding) {
            Text("No variant").tag(String?.none)
            ForEach(registry.variants) { variant in
                Text(variant.label).tag(String?.some(variant.slug))
            }
        }
        .disabled(registry.variants.isEmpty)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch registry.loadState {
        case .loading, .idle:
            Text("Loading variants...")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            retryRow
        case .loaded:
            whatToTestRow
        }
    }

    /// The chosen variant's what-to-test, so the tester can confirm what they
    /// are about to route new conversations through before leaving the screen.
    @ViewBuilder
    private var whatToTestRow: some View {
        let selected: ConvosAPI.AgentVariant? = registry.variant(withSlug: FeatureFlags.shared.selectedAgentVariant?.slug)
        if let selected, !selected.whatToTest.isEmpty {
            Text(selected.whatToTest)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var retryRow: some View {
        let retry: () -> Void = {
            Task { await registry.reload() }
        }
        return Button(action: retry) {
            HStack {
                Text("Couldn't load variants")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0.0)
                Text("Retry")
                    .font(.caption)
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { FeatureFlags.shared.selectedAgentVariant?.slug },
            set: { newValue in
                FeatureFlags.shared.selectedAgentVariant = registry.variant(withSlug: newValue)
            }
        )
    }
}
