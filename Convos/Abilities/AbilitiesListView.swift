import ConvosCore
import SwiftUI

/// Owns the abilities list view model via `@State`, so it is created once
/// per navigation push or sheet presentation and survives re-evaluation
/// of the presenting builder. Entry points must present this wrapper:
/// constructing `AbilitiesListViewModel` inline in a navigation
/// destination or sheet-content builder would hand `AbilitiesListView` a
/// fresh model on every parent invalidation, silently dropping loaded
/// catalog, busy, and pending-authorization state (and the list's
/// `.task`, keyed to view identity, would not re-fire for the
/// replacement).
struct AbilitiesListScreen: View {
    @State private var viewModel: AbilitiesListViewModel

    init(service: any AbilitiesServiceProtocol) {
        _viewModel = State(initialValue: AbilitiesListViewModel(service: service))
    }

    var body: some View {
        AbilitiesListView(viewModel: viewModel)
    }
}

/// The V2 abilities catalog list (account level): searchable, split into
/// entitled and available sections, with status badges and
/// connect/disconnect actions stubbed through `AbilitiesServiceProtocol`.
///
/// Entry points (all flag-gated behind Abilities V2, all via
/// `AbilitiesListScreen`, which owns the view model):
/// - App Settings connections row (`AppSettingsView.connectionsDestination`)
///   pushes it in place of the V1 `ConnectionsListView`.
/// - The conversation abilities section presents it as a sheet when a
///   toggle needs an entitlement (`ConversationAbilitiesSection`).
struct AbilitiesListView: View {
    @Bindable var viewModel: AbilitiesListViewModel

    var body: some View {
        catalogList
            .searchable(text: $viewModel.searchText, prompt: "Search abilities")
            .overlay { listOverlay }
            .task { await viewModel.refresh() }
            .sheet(item: $viewModel.pendingAuthorization, onDismiss: handleAuthorizationDismissed) { context in
                authorizationSheet(context)
            }
    }

    private var catalogList: some View {
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
            unknownStateSection
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
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
    /// state. Rows carry last-known state; rows with no last-known state
    /// render in the state-unknown section, never as "not connected".
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
        } else if viewModel.isSearching, !viewModel.hasVisibleAbilities {
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

    /// Outage with no last-known state: the catalog stays browsable but
    /// connect controls are withheld until an authoritative response.
    @ViewBuilder
    private var unknownStateSection: some View {
        if !viewModel.unknownStateAbilities.isEmpty {
            Section {
                ForEach(viewModel.unknownStateAbilities) { ability in
                    unknownStateRow(ability)
                }
            } header: {
                sectionHeader("Abilities")
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

    private func unknownStateRow(_ ability: AbilitiesAPI.Ability) -> some View {
        abilityRowContent(ability, subtitle: "Status unavailable") {
            EmptyView()
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
        let continueAction = { viewModel.connect(ability) }
        let disconnectAction = { viewModel.disconnect(ability) }
        return Menu {
            switch status {
            case .pendingAuth:
                Button("Continue connecting", action: continueAction)
            case .expired, .needsReauth, .revoked:
                Button("Reconnect", action: continueAction)
            case .active:
                EmptyView()
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

    // MARK: - Sheets

    private func authorizationSheet(_ context: AbilityAuthorizationContext) -> some View {
        AbilityAuthorizationSheet(
            context: context,
            onAuthorize: { viewModel.completeAuthorization(context) },
            onCancel: { viewModel.cancelAuthorization() }
        )
    }

    /// Fires for every dismissal of the authorization sheet -- Cancel tap,
    /// swipe-down, or programmatic -- so all paths share one cancel
    /// lifecycle in the view model.
    private func handleAuthorizationDismissed() {
        viewModel.handleAuthorizationDismissed()
    }
}

// MARK: - Previews

#Preview("Standard") {
    NavigationStack {
        AbilitiesListScreen(service: MockAbilitiesService())
    }
}

#Preview("Entitlements unavailable") {
    NavigationStack {
        AbilitiesListScreen(service: MockAbilitiesService(scenario: .entitlementsUnavailable))
    }
}

#Preview("Cold-start outage") {
    NavigationStack {
        AbilitiesListScreen(service: MockAbilitiesService(scenario: .entitlementsUnavailableColdStart))
    }
}

#Preview("Device only") {
    NavigationStack {
        AbilitiesListScreen(service: MockAbilitiesService(scenario: .deviceOnly))
    }
}
