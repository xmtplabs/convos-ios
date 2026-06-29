import ConvosCore
import SwiftUI

/// Loads the dev variant registry (`GET /v2/agent-variants`) and tracks the
/// chosen one, mirrored into `FeatureFlags.selectedAgentVariant` so `commit()`
/// can thread its slug through the build. A persisted selection whose slug is
/// gone from the live registry silently falls back to no variant.
@MainActor
@Observable
final class AgentVariantSelectorViewModel {
    enum LoadState {
        case loading
        case loaded
        case failed
    }

    private(set) var variants: [ConvosAPI.AgentVariant] = []
    private(set) var loadState: LoadState = .loading
    /// The chosen variant (`nil` = none). A stored mirror of
    /// `FeatureFlags.selectedAgentVariant` so the view reacts to selection.
    private(set) var selectedVariant: ConvosAPI.AgentVariant?

    private let apiClient: any ConvosAPIClientProtocol

    init(apiClient: any ConvosAPIClientProtocol = ConvosAPIClientFactory.client(environment: ConfigManager.shared.currentEnvironment)) {
        self.apiClient = apiClient
        self.selectedVariant = FeatureFlags.shared.selectedAgentVariant
    }

    func isSelected(_ variant: ConvosAPI.AgentVariant) -> Bool {
        selectedVariant?.slug == variant.slug
    }

    func load() async {
        loadState = .loading
        do {
            let fetched = try await apiClient.getAgentVariants()
            variants = fetched
            reconcileSelection(against: fetched)
            loadState = .loaded
        } catch {
            Log.error("AgentVariantSelector: failed to load variants: \(error.localizedDescription)")
            loadState = .failed
        }
    }

    func select(_ variant: ConvosAPI.AgentVariant?) {
        FeatureFlags.shared.selectedAgentVariant = variant
        selectedVariant = variant
    }

    private func reconcileSelection(against fetched: [ConvosAPI.AgentVariant]) {
        guard let slug = selectedVariant?.slug else { return }
        guard !fetched.contains(where: { $0.slug == slug }) else { return }
        FeatureFlags.shared.selectedAgentVariant = nil
        selectedVariant = nil
    }
}

/// Dev-only variant selector for the make-an-agent composer, gated by
/// `FeatureFlags.isAgentVariantSelectorEnabled`. A dropdown of variant labels
/// ("No variant" plus the live registry); the chosen one's full what-to-test
/// renders below via `ConversationVariantBanner` so the builder reviews it
/// before Make.
struct AgentVariantSelector: View {
    @State private var viewModel: AgentVariantSelectorViewModel = AgentVariantSelectorViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            menu
            if let selected = viewModel.selectedVariant {
                ConversationVariantBanner(variant: selected.stamp)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await viewModel.load() }
    }

    private var menu: some View {
        Menu {
            let selectNone = { viewModel.select(nil) }
            Button(action: selectNone) {
                menuItemLabel(title: "No variant", selected: viewModel.selectedVariant == nil)
            }
            switch viewModel.loadState {
            case .loaded:
                ForEach(viewModel.variants) { variant in
                    let selectVariant = { viewModel.select(variant) }
                    Button(action: selectVariant) {
                        menuItemLabel(title: variant.label, selected: viewModel.isSelected(variant))
                    }
                }
            case .loading:
                Text("Loading variants...")
            case .failed:
                Text("Couldn't load variants")
            }
        } label: {
            menuButtonLabel
        }
    }

    @ViewBuilder
    private func menuItemLabel(title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var menuTitle: String {
        guard let variant = viewModel.selectedVariant else { return "No variant" }
        return "🧪 \(variant.label)"
    }

    private var menuButtonLabel: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            Text(menuTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.colorTextPrimary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.colorTextSecondary)
            Spacer(minLength: 0.0)
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
        .background(
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                .fill(.colorFillMinimal)
        )
    }
}
