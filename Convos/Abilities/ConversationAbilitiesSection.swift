import ConvosCore
import SwiftUI

/// The V2 per-conversation abilities section shown in conversation info
/// when the Abilities V2 flag is on (the V1 `ConversationConnectionsSection`
/// renders otherwise; see `ConversationInfoView.agentAccessSection`).
///
/// One toggle per ability per agent: single-agent conversations render one
/// plain toggle per ability, multi-agent conversations label each row with
/// the agent it extends to. Toggling on a multi-bundle ability opens the
/// bundle picker; toggling an ability without an active entitlement opens
/// the abilities list to connect it first.
struct ConversationAbilitiesSection: View {
    @Bindable var viewModel: ConversationAbilitiesViewModel

    var body: some View {
        Section {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.colorCaution)
            }
            ForEach(viewModel.rows) { row in
                abilityToggleRow(row)
            }
        } header: {
            Text("Abilities")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.colorTextSecondary)
        }
        .sheet(item: $viewModel.bundleSelection) { context in
            bundleSelectionSheet(context)
        }
        .sheet(item: $viewModel.needsEntitlementAbility, onDismiss: handleSheetDismissed) { ability in
            needsEntitlementSheet(ability)
        }
    }

    // MARK: - Rows

    private func abilityToggleRow(_ row: ConversationAbilitiesViewModel.Row) -> some View {
        let binding = Binding(
            get: { row.isOn },
            set: { _ in viewModel.toggle(row) }
        )
        return FeatureRowItem(
            imageName: nil,
            symbolName: AbilityIconView.symbolName(for: row.ability.id),
            title: row.ability.displayName.resolved(),
            subtitle: subtitle(for: row),
            iconBackgroundColor: .colorFillMinimal,
            iconForegroundColor: .colorTextPrimary
        ) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .disabled(viewModel.isBusy)
        }
        .accessibilityIdentifier("conversation-ability-\(row.id)")
    }

    /// Single-agent rows read like the V1 section; multi-agent rows name
    /// the agent the toggle extends to. An ability without an active
    /// entitlement advertises the connect-first step.
    private func subtitle(for row: ConversationAbilitiesViewModel.Row) -> String {
        let needsEntitlement: Bool = row.ability.entitlement?.status != .active
        if !viewModel.isSingleAgent {
            return "For \(row.agent.displayName)"
        }
        if needsEntitlement, !row.isOn {
            return "Connect to use in this convo"
        }
        return row.ability.subtitle.resolved()
    }

    // MARK: - Sheets

    private func bundleSelectionSheet(_ context: AbilityBundleSelectionContext) -> some View {
        AbilityBundleSelectionSheet(context: context) { bundleIds in
            viewModel.extend(ability: context.ability, agent: context.agent, bundleIds: bundleIds)
        }
    }

    /// The needs-entitlement deep link: the account-level abilities list on
    /// the same service, so connecting here is reflected in the toggles
    /// after dismissal.
    private func needsEntitlementSheet(_ ability: AbilitiesAPI.Ability) -> some View {
        NavigationStack {
            AbilitiesListView(viewModel: viewModel.makeAbilitiesListViewModel())
                .navigationTitle("Connect \(ability.displayName.resolved())")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func handleSheetDismissed() {
        viewModel.refreshSoon()
    }
}

// MARK: - Previews

#Preview("Single agent") {
    List {
        ConversationAbilitiesSection(
            viewModel: ConversationAbilitiesViewModel(
                conversationId: "mock-conversation-1",
                agents: [
                    ConversationAgentDescriptor(inboxId: "mock-agent-inbox-1", displayName: "Caley"),
                ],
                service: MockAbilitiesService()
            )
        )
    }
}

#Preview("Two agents") {
    List {
        ConversationAbilitiesSection(
            viewModel: ConversationAbilitiesViewModel(
                conversationId: "mock-conversation-1",
                agents: [
                    ConversationAgentDescriptor(inboxId: "mock-agent-inbox-1", displayName: "Caley"),
                    ConversationAgentDescriptor(inboxId: "mock-agent-inbox-2", displayName: "Scout"),
                ],
                service: MockAbilitiesService()
            )
        )
    }
}

#Preview("Entitlements unavailable") {
    List {
        ConversationAbilitiesSection(
            viewModel: ConversationAbilitiesViewModel(
                conversationId: "mock-conversation-1",
                agents: [
                    ConversationAgentDescriptor(inboxId: "mock-agent-inbox-1", displayName: "Caley"),
                ],
                service: MockAbilitiesService(scenario: .entitlementsUnavailable)
            )
        )
    }
}
