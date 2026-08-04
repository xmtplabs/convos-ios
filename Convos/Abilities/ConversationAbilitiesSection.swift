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
/// opens the inline connect sheet instead of presenting a usable toggle.
/// Toggling on a multi-bundle ability opens the bundle picker; toggling an
/// ability without an active entitlement opens the inline connect sheet
/// (`AbilityConnectSheet`) and, once connected, continues into the
/// extension without leaving the conversation.
/// The section renders rows only; its bundle and connect sheets are hosted
/// by `ConversationAbilitiesSheetsModifier`, which the presenting screen
/// applies at its list level. Sheet modifiers attached to the `Section`
/// itself resolve the wrong presentation context from inside the
/// already-presented info sheet: the toggle's sheet then dismisses the
/// info sheet instead of presenting, dead-ending the flow.
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
    /// a badge, and the whole row opens the inline connect sheet to
    /// reconnect.
    private func needsAttentionRow(
        _ row: ConversationAbilitiesViewModel.Row,
        status: AbilitiesAPI.EntitlementStatus?
    ) -> some View {
        let reconnectAction = { viewModel.presentConnect(for: row) }
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
}

/// Hosts the abilities section's two sheets (bundle picker and inline
/// connect) for a presenting screen. Applied to `ConversationInfoView`'s
/// list, next to its other working sheet attachments -- never to the
/// `Section` (see `ConversationAbilitiesSection`).
struct ConversationAbilitiesSheetsModifier: ViewModifier {
    /// Nil when the conversation renders the V1 connections section or has
    /// no agent; both sheets then simply never present.
    let viewModel: ConversationAbilitiesViewModel?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let viewModel {
            content.modifier(ConversationAbilitiesActiveSheetsModifier(viewModel: viewModel))
        } else {
            content
        }
    }
}

/// The non-nil half of `ConversationAbilitiesSheetsModifier`. `@Bindable`
/// projects the view model's sheet contexts as observation-tracked
/// bindings; a hand-rolled `Binding(get:set:)` pair is not tracked, so the
/// sheets would never present when the view model publishes a context.
private struct ConversationAbilitiesActiveSheetsModifier: ViewModifier {
    @Bindable var viewModel: ConversationAbilitiesViewModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $viewModel.bundleSelection) { context in
                bundleSelectionSheet(context)
            }
            .sheet(item: $viewModel.connectContext, onDismiss: handleConnectSheetDismissed) { context in
                connectSheet(context)
            }
    }

    private func bundleSelectionSheet(_ context: AbilityBundleSelectionContext) -> some View {
        AbilityBundleSelectionSheet(context: context) { bundleIds in
            viewModel.extend(ability: context.ability, agent: context.agent, bundleIds: bundleIds)
        }
    }

    /// The no-entitlement path: an inline connect flow for the tapped
    /// ability on the same service selection as the rows, so a successful
    /// connect continues straight into the extension
    /// (`ConversationAbilitiesViewModel.handleConnected`). Replaces the old
    /// abilities-list deep link, which dead-ended the toggle.
    private func connectSheet(_ context: ConversationAbilityConnectContext) -> some View {
        AbilityConnectSheet(
            ability: context.ability,
            selection: viewModel.abilitiesSelection,
            onConnected: { viewModel.handleConnected($0) }
        )
    }

    private func handleConnectSheetDismissed() {
        viewModel.handleConnectSheetDismissed()
    }
}

// MARK: - Previews

#Preview("Single agent") {
    let viewModel = ConversationAbilitiesViewModel(
        conversationId: "mock-conversation-1",
        agents: [
            ConversationAgentDescriptor(inboxId: "mock-agent-inbox-1", displayName: "Caley"),
        ],
        selection: AbilitiesSelection(service: MockAbilitiesService())
    )
    List {
        ConversationAbilitiesSection(viewModel: viewModel)
    }
    .modifier(ConversationAbilitiesSheetsModifier(viewModel: viewModel))
}

#Preview("Two agents") {
    let viewModel = ConversationAbilitiesViewModel(
        conversationId: "mock-conversation-1",
        agents: [
            ConversationAgentDescriptor(inboxId: "mock-agent-inbox-1", displayName: "Caley"),
            ConversationAgentDescriptor(inboxId: "mock-agent-inbox-2", displayName: "Scout"),
        ],
        selection: AbilitiesSelection(service: MockAbilitiesService())
    )
    List {
        ConversationAbilitiesSection(viewModel: viewModel)
    }
    .modifier(ConversationAbilitiesSheetsModifier(viewModel: viewModel))
}

#Preview("Entitlements unavailable") {
    let viewModel = ConversationAbilitiesViewModel(
        conversationId: "mock-conversation-1",
        agents: [
            ConversationAgentDescriptor(inboxId: "mock-agent-inbox-1", displayName: "Caley"),
        ],
        selection: AbilitiesSelection(service: MockAbilitiesService(scenario: .entitlementsUnavailable))
    )
    List {
        ConversationAbilitiesSection(viewModel: viewModel)
    }
    .modifier(ConversationAbilitiesSheetsModifier(viewModel: viewModel))
}

#Preview("Cold-start outage") {
    let viewModel = ConversationAbilitiesViewModel(
        conversationId: "mock-conversation-1",
        agents: [
            ConversationAgentDescriptor(inboxId: "mock-agent-inbox-1", displayName: "Caley"),
        ],
        selection: AbilitiesSelection(service: MockAbilitiesService(scenario: .entitlementsUnavailableColdStart))
    )
    List {
        ConversationAbilitiesSection(viewModel: viewModel)
    }
    .modifier(ConversationAbilitiesSheetsModifier(viewModel: viewModel))
}
