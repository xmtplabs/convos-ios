import ConvosCore
import SwiftUI

/// Owns the ability detail view model via `@State`, so it is created once
/// per navigation push and survives re-evaluation of the presenting
/// builder. Entry points must push this wrapper: constructing
/// `AbilityDetailViewModel` inline in a navigation destination would hand
/// `AbilityDetailView` a fresh model on every parent invalidation,
/// silently dropping loaded delegations (and the list's `.task`, keyed to
/// view identity, would not re-fire for the replacement). Same rationale
/// as `AbilitiesListScreen`.
struct AbilityDetailScreen: View {
    @State private var viewModel: AbilityDetailViewModel

    init(ability: AbilitiesAPI.Ability, selection: AbilitiesSelection) {
        _viewModel = State(initialValue: AbilityDetailViewModel(ability: ability, selection: selection))
    }

    var body: some View {
        AbilityDetailView(viewModel: viewModel)
    }
}

/// One ability's detail: identity header plus every delegation granted
/// against it, split into active and earlier, with owner-initiated
/// revocation on active rows.
///
/// Reachable only from `AbilitiesListView`'s entitled rows, which are
/// themselves only reachable from surfaces already gated by the Abilities
/// V2 flag -- no extra flag check needed here.
struct AbilityDetailView: View {
    @Bindable var viewModel: AbilityDetailViewModel

    var body: some View {
        List {
            headerSection
            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }
            delegationsSection
            earlierSection
        }
        .scrollContentBackground(.hidden)
        .background(.colorBackgroundRaisedSecondary)
        .navigationTitle(viewModel.ability.displayName.resolved())
        .navigationBarTitleDisplayMode(.inline)
        .overlay { emptyStateOverlay }
        .task { await viewModel.refresh() }
        .accessibilityIdentifier("ability-detail-\(viewModel.ability.id)")
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                AbilityIconView(ability: viewModel.ability)
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(viewModel.ability.displayName.resolved())
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                    Text(viewModel.ability.subtitle.resolved())
                        .font(.footnote)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(2)
                }
                Spacer()
                if let entitlement = viewModel.ability.entitlement {
                    AbilityStatusBadge(status: entitlement.status)
                }
            }
        }
    }

    @ViewBuilder
    private var delegationsSection: some View {
        if !viewModel.activeDelegations.isEmpty {
            Section {
                ForEach(viewModel.activeDelegations) { delegation in
                    activeDelegationRow(delegation)
                }
            } header: {
                sectionHeader("Delegations")
            }
        }
    }

    @ViewBuilder
    private var earlierSection: some View {
        if !viewModel.pastDelegations.isEmpty {
            Section {
                ForEach(viewModel.pastDelegations) { delegation in
                    delegationRow(delegation)
                }
            } header: {
                sectionHeader("Earlier")
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.colorTextSecondary)
    }

    private func errorBanner(_ message: String) -> some View {
        Section {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.colorCaution)
        }
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
        if viewModel.delegations.isEmpty, !viewModel.isLoading {
            ContentUnavailableView(
                "No delegations",
                systemImage: "person.badge.key",
                description: Text("When an agent asks to use \(viewModel.ability.displayName.resolved()), what you allow shows up here.")
            )
        }
    }

    // MARK: - Rows

    /// Active rows carry the revoke affordances (swipe + context menu);
    /// past rows are inert.
    private func activeDelegationRow(_ delegation: AbilityDelegation) -> some View {
        let revokeAction = { viewModel.revoke(delegation) }
        return delegationRow(delegation)
            .swipeActions(edge: .trailing) {
                Button("Revoke", role: .destructive, action: revokeAction)
                    .accessibilityIdentifier("delegation-revoke-\(delegation.id)")
            }
            .contextMenu {
                Button("Revoke", role: .destructive, action: revokeAction)
            }
    }

    private func delegationRow(_ delegation: AbilityDelegation) -> some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            delegationRowTitles(delegation)
            Spacer()
            AbilityDelegationStateChip(state: delegation.effectiveState())
        }
        .accessibilityIdentifier("delegation-row-\(delegation.id)")
    }

    private func delegationRowTitles(_ delegation: AbilityDelegation) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            Text(delegation.conversationName)
                .font(.body)
                .foregroundStyle(.colorTextPrimary)
            Text("\(delegation.agentDisplayName) - \(viewModel.bundlesSummary(for: delegation))")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
            Text(scopeLine(delegation))
                .font(.footnote)
                .foregroundStyle(.colorTextTertiary)
        }
    }

    private func scopeLine(_ delegation: AbilityDelegation) -> String {
        switch delegation.scope {
        case .oneShot:
            return "Just once"
        case .expiring(let expiry):
            let formatted: String = expiry.formatted(date: .abbreviated, time: .omitted)
            return "Until \(formatted)"
        }
    }
}

// MARK: - Previews

#Preview("Populated") {
    let gcal = MockAbilitiesService.standardCatalog().first { $0.id == "googlecalendar" }
    if let gcal {
        NavigationStack {
            AbilityDetailScreen(
                ability: gcal,
                selection: AbilitiesSelection(
                    service: MockAbilitiesService(),
                    escalation: MockAbilityEscalationService(scenario: .populated)
                )
            )
        }
    }
}

#Preview("Empty") {
    let youtube = MockAbilitiesService.standardCatalog().first { $0.id == "youtube" }
    if let youtube {
        NavigationStack {
            AbilityDetailScreen(
                ability: youtube,
                selection: AbilitiesSelection(
                    service: MockAbilitiesService(),
                    escalation: MockAbilityEscalationService(scenario: .quiet)
                )
            )
        }
    }
}
