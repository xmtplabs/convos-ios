import ConvosCore
import SwiftUI

/// The per-conversation enablement control for one (ability, agent) pair.
///
/// The single implementation behind both surfaces that offer it: the
/// conversation info section (`ConversationAbilitiesSection`) and the
/// Connections browser's Connected section in `.composerModal`
/// (`AbilitiesListView`). State, writer, and the disabled rule live in the
/// view model and have exactly one implementation here; row *chrome*
/// stays per-surface. Only the repair route differs, which is why it is a
/// parameter and not a branch.
struct ConversationAbilityToggleControl: View {
    let row: ConversationAbilitiesViewModel.Row
    let viewModel: ConversationAbilitiesViewModel
    /// Runs when the row's entitlement needs repair (`.needsAttention`,
    /// `.needsEntitlement`). The info view presents its own scoped connect
    /// sheet; the browser forwards to the connect flow already on screen,
    /// which would otherwise be a second connect sheet on one screen.
    let onNeedsAttention: () -> Void

    var body: some View {
        switch row.lifecycle {
        case .needsAttention(let status):
            attentionControl(status)
        case .ready, .needsEntitlement, .unknown:
            toggleControl
        }
    }

    /// The toggle reads on while an auto-enable is still landing, with a
    /// spinner beside it: the member must never see the thing they just
    /// connected settle as OFF. Its on state is the same green the
    /// entitlement's "Active" badge and the capability approval toggle
    /// use, so "on" reads the same everywhere it appears.
    private var toggleControl: some View {
        let binding: Binding<Bool> = Binding(
            get: { row.isOn },
            set: { _ in viewModel.toggle(row) }
        )
        let showsProgress: Bool = row.isPendingEnablement
        let isDisabled: Bool = viewModel.isToggleDisabled(for: row)
        return HStack(spacing: DesignConstants.Spacing.stepX) {
            if showsProgress {
                ProgressView()
            }
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(.colorGreen)
                .disabled(isDisabled)
        }
    }

    private func attentionControl(_ status: AbilitiesAPI.EntitlementStatus?) -> some View {
        Button(action: onNeedsAttention) {
            attentionBadge(status)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.entitlementsUnavailable)
    }

    /// A server-owned status renders its badge; an opt-in with no
    /// entitlement at all (authoritative null) gets a neutral "Not
    /// connected" badge -- the server never said "revoked", so the UI
    /// must not either.
    @ViewBuilder
    private func attentionBadge(_ status: AbilitiesAPI.EntitlementStatus?) -> some View {
        if let status {
            AbilityStatusBadge(status: status)
        } else {
            AbilityNeutralBadge(label: "Not connected")
        }
    }
}

/// Stands in for the control on a Connected row the conversation view
/// model has not produced a row for yet (the catalog that sectioned the
/// row landed first). Loading, never a settled OFF: reading the gap as
/// "not enabled here" would invite a tap that extends with manifest
/// defaults over a selection the member already made.
struct ConversationAbilityToggleLoadingControl: View {
    var body: some View {
        ProgressView()
            .accessibilityLabel("Loading connection state")
    }
}
