import ConvosCore
import SwiftUI

/// The V2 abilities catalog list (account level): searchable, split into
/// entitled and available sections, with status badges and
/// connect/disconnect actions stubbed through `AbilitiesServiceProtocol`.
///
/// Entry points (all flag-gated behind Abilities V2):
/// - App Settings connections row (`AppSettingsView.connectionsDestination`)
///   pushes it in place of the V1 `ConnectionsListView`.
/// - The conversation abilities section presents it as a sheet when a
///   toggle needs an entitlement (`ConversationAbilitiesSection`).
struct AbilitiesListView: View {
    @Bindable var viewModel: AbilitiesListViewModel

    var body: some View {
        List {
            headerSection
            if viewModel.entitlementsUnavailable {
                unavailableBanner
            }
            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }
            entitledSection
            availableSection
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .searchable(text: $viewModel.searchText, prompt: "Search abilities")
        .overlay { listOverlay }
        .task { await viewModel.refresh() }
        .accessibilityIdentifier("abilities-list")
    }

    // MARK: - Chrome

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Abilities")
                    .font(.convosTitle)
                    .tracking(Font.convosTitleTracking)
                    .foregroundStyle(.colorTextPrimary)
                Text("Give agents new powers in your convos")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextPrimary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step2x)
            .listRowBackground(Color.clear)
        }
        .listRowSeparator(.hidden)
        .listRowSpacing(0.0)
        .listRowInsets(.all, DesignConstants.Spacing.step2x)
        .listSectionMargins(.top, 0.0)
        .listSectionSeparator(.hidden)
    }

    /// Shown when the backend served the catalog without entitlement
    /// state; the rows below carry last-known state, never "not connected".
    private var unavailableBanner: some View {
        Section {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.colorLava)
                Text("Can't check ability status right now. Showing the last-known state.")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }
            .accessibilityIdentifier("abilities-unavailable-banner")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Section {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.colorCaution)
        }
    }

    @ViewBuilder
    private var listOverlay: some View {
        if viewModel.isLoading, !viewModel.hasLoadedOnce {
            ProgressView()
        } else if viewModel.isSearching, viewModel.entitledAbilities.isEmpty, viewModel.availableAbilities.isEmpty {
            ContentUnavailableView.search(text: viewModel.searchText)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var entitledSection: some View {
        if !viewModel.entitledAbilities.isEmpty {
            Section {
                ForEach(viewModel.entitledAbilities) { ability in
                    entitledRow(ability)
                }
            } header: {
                sectionHeader("Connected")
            }
        }
    }

    @ViewBuilder
    private var availableSection: some View {
        if !viewModel.availableAbilities.isEmpty {
            Section {
                ForEach(viewModel.availableAbilities) { ability in
                    availableRow(ability)
                }
            } header: {
                sectionHeader("Available")
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.colorTextSecondary)
    }

    // MARK: - Rows

    private func entitledRow(_ ability: AbilitiesAPI.Ability) -> some View {
        abilityRowContent(ability, subtitle: entitledSubtitle(for: ability)) {
            entitledAccessory(ability)
        }
    }

    private func availableRow(_ ability: AbilitiesAPI.Ability) -> some View {
        abilityRowContent(ability, subtitle: ability.subtitle.resolved()) {
            availableAccessory(ability)
        }
    }

    private func abilityRowContent(
        _ ability: AbilitiesAPI.Ability,
        subtitle: String,
        @ViewBuilder accessory: () -> some View
    ) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            AbilityIconView(ability: ability)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                Text(ability.displayName.resolved())
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            accessory()
        }
        .accessibilityIdentifier("ability-row-\(ability.id)")
    }

    /// The entitled row's second line: how broadly the entitlement is in
    /// use, falling back to the server subtitle when unextended.
    private func entitledSubtitle(for ability: AbilitiesAPI.Ability) -> String {
        let count: Int = ability.entitlement?.extensionCount ?? 0
        switch count {
        case 0: return ability.subtitle.resolved()
        case 1: return "Used in 1 convo"
        default: return "Used in \(count) convos"
        }
    }

    // MARK: - Accessories

    @ViewBuilder
    private func entitledAccessory(_ ability: AbilitiesAPI.Ability) -> some View {
        if viewModel.isBusy(ability) {
            ProgressView()
        } else if let entitlement = ability.entitlement {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                AbilityStatusBadge(status: entitlement.status)
                entitledMenu(ability, status: entitlement.status)
            }
        }
    }

    private func entitledMenu(_ ability: AbilitiesAPI.Ability, status: AbilitiesAPI.EntitlementStatus) -> some View {
        let needsReconnect: Bool = status == .expired || status == .needsReauth
        let reconnectAction = { viewModel.connect(ability) }
        let disconnectAction = { viewModel.disconnect(ability) }
        return Menu {
            if needsReconnect {
                Button("Reconnect", action: reconnectAction)
            }
            Button("Disconnect", role: .destructive, action: disconnectAction)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .frame(width: DesignConstants.Spacing.step6x, height: DesignConstants.Spacing.step6x)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("ability-menu-\(ability.id)")
    }

    @ViewBuilder
    private func availableAccessory(_ ability: AbilitiesAPI.Ability) -> some View {
        if viewModel.isBusy(ability) {
            ProgressView()
        } else {
            let connectAction = { viewModel.connect(ability) }
            Button(action: connectAction) {
                Text("Connect")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .padding(.vertical, DesignConstants.Spacing.stepX)
                    .background(Capsule().fill(Color.colorFillMinimal))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ability-connect-\(ability.id)")
        }
    }
}

// MARK: - Previews

#Preview("Standard") {
    NavigationStack {
        AbilitiesListView(
            viewModel: AbilitiesListViewModel(service: MockAbilitiesService())
        )
    }
}

#Preview("Entitlements unavailable") {
    NavigationStack {
        AbilitiesListView(
            viewModel: AbilitiesListViewModel(service: MockAbilitiesService(scenario: .entitlementsUnavailable))
        )
    }
}

#Preview("Device only") {
    NavigationStack {
        AbilitiesListView(
            viewModel: AbilitiesListViewModel(service: MockAbilitiesService(scenario: .deviceOnly))
        )
    }
}
