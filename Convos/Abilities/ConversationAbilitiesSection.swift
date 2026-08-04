import ConvosCore
import SwiftUI

/// The V2 per-conversation abilities section shown in conversation info
/// when the Abilities V2 flag is on (the V1 `ConversationConnectionsSection`
/// renders otherwise; see `ConversationInfoView.agentAccessSection`).
///
/// One toggle per ability per agent: single-agent conversations render one
/// plain toggle per ability, multi-agent conversations label each row with
/// the agent it extends to. Rows honor the entitlement lifecycle: an
/// opt-in backed by a non-active entitlement renders its status badge and
/// deep-links to the abilities list instead of presenting a usable toggle.
/// Toggling on a multi-bundle ability opens the bundle picker; toggling an
/// ability without an active entitlement opens the abilities list to
/// connect it first.
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
                abilityRow(row)
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

    @ViewBuilder
    private func abilityRow(_ row: ConversationAbilitiesViewModel.Row) -> some View {
        switch row.lifecycle {
        case .needsAttention(let status):
            needsAttentionRow(row, status: status)
        case .ready, .needsEntitlement, .unknown:
            toggleRow(row)
        }
    }

    private func toggleRow(_ row: ConversationAbilitiesViewModel.Row) -> some View {
        let binding: Binding<Bool> = Binding(
            get: { row.isOn },
            set: { _ in viewModel.toggle(row) }
        )
        let isDisabled: Bool = viewModel.isBusy || row.lifecycle == .unknown
        return featureRow(row) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .disabled(isDisabled)
        }
    }

    /// An opt-in whose entitlement is no longer active: no usable toggle,
    /// a badge, and the whole row deep-links to the abilities list to
    /// reconnect.
    private func needsAttentionRow(
        _ row: ConversationAbilitiesViewModel.Row,
        status: AbilitiesAPI.EntitlementStatus?
    ) -> some View {
        let reconnectAction = { viewModel.needsEntitlementAbility = row.ability }
        return Button(action: reconnectAction) {
            featureRow(row) {
                attentionBadge(status: status)
            }
        }
        .buttonStyle(.plain)
    }

    /// A server-owned status renders its badge; an opt-in with no
    /// entitlement at all (authoritative null) gets a neutral "Not
    /// connected" badge -- the server never said "revoked", so the UI
    /// must not either.
    @ViewBuilder
    private func attentionBadge(status: AbilitiesAPI.EntitlementStatus?) -> some View {
        if let status {
            AbilityStatusBadge(status: status)
        } else {
            AbilityNeutralBadge(label: "Not connected")
        }
    }

    private func featureRow(
        _ row: ConversationAbilitiesViewModel.Row,
        @ViewBuilder accessory: @escaping () -> some View
    ) -> some View {
        FeatureRowItem(
            imageName: nil,
            symbolName: AbilityIconView.symbolName(for: row.ability.id),
            title: row.ability.displayName.resolved(),
            subtitle: subtitle(for: row),
            iconBackgroundColor: .colorFillMinimal,
            iconForegroundColor: .colorTextPrimary
        ) {
            accessory()
        }
        .accessibilityIdentifier("conversation-ability-\(row.ability.id)-\(row.agent.inboxId)")
    }

    /// Single-agent rows read like the V1 section; multi-agent rows name
    /// the agent the toggle extends to. Lifecycle problems always surface,
    /// in both layouts.
    private func subtitle(for row: ConversationAbilitiesViewModel.Row) -> String {
        let base: String = viewModel.isSingleAgent ? row.ability.subtitle.resolved() : "For \(row.agent.displayName)"
        switch row.lifecycle {
        case .ready:
            return base
        case .needsAttention(let status):
            let warning: String = attentionWarning(for: status)
            return viewModel.isSingleAgent ? warning : "\(base) - \(warning)"
        case .needsEntitlement:
            return viewModel.isSingleAgent ? "Connect to use in this convo" : "\(base) - not connected"
        case .unknown:
            return viewModel.isSingleAgent ? "Status unavailable" : "\(base) - status unavailable"
        }
    }

    private func attentionWarning(for status: AbilitiesAPI.EntitlementStatus?) -> String {
        switch status {
        case .expired: "Expired, tap to reconnect"
        case .needsReauth: "Needs reauthorization, tap to fix"
        case .pendingAuth: "Authorization pending, tap to finish"
        case .revoked: "Disconnected, tap to reconnect"
        case .none: "Not connected, tap to reconnect"
        case .active: ""
        }
    }

    // MARK: - Sheets

    private func bundleSelectionSheet(_ context: AbilityBundleSelectionContext) -> some View {
        AbilityBundleSelectionSheet(context: context) { bundleIds in
            viewModel.extend(ability: context.ability, agent: context.agent, bundleIds: bundleIds)
        }
    }

    /// The needs-entitlement deep link: the account-level abilities list on
    /// the same service, so connecting here is reflected in the toggles
    /// after dismissal (`handleSheetDismissed` refreshes). The screen
    /// wrapper owns the list view model via `@State`, so re-evaluations of
    /// this sheet-content builder cannot replace it mid-presentation.
    private func needsEntitlementSheet(_ ability: AbilitiesAPI.Ability) -> some View {
        NavigationStack {
            AbilitiesListScreen(service: viewModel.abilitiesService)
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

#Preview("Cold-start outage") {
    List {
        ConversationAbilitiesSection(
            viewModel: ConversationAbilitiesViewModel(
                conversationId: "mock-conversation-1",
                agents: [
                    ConversationAgentDescriptor(inboxId: "mock-agent-inbox-1", displayName: "Caley"),
                ],
                service: MockAbilitiesService(scenario: .entitlementsUnavailableColdStart)
            )
        )
    }
}
