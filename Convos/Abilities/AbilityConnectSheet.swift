import ConvosCore
import SwiftUI

/// Inline connect flow for a single ability, so a toggle that needs an
/// entitlement resolves right where it was tapped.
///
/// Entry points:
/// - `ConversationAbilitiesSection` presents it as a sheet when a toggle
///   (or a needs-attention row) has no active entitlement; on success the
///   section's view model continues into the extension
///   (`ConversationAbilitiesViewModel.handleConnected`).
///
/// The flow reuses the account-level connect machinery via
/// `AbilitiesListViewModel` (begin, browser or stub authorization,
/// completion retries), scoped to one ability. In live mode the Connect
/// button opens the `ASWebAuthenticationSession` browser; in mock mode the
/// stub `AbilityAuthorizationSheet` content swaps in inline -- nesting
/// another sheet inside this one is exactly the presentation shape this
/// flow exists to avoid. Success is observed on the refreshed catalog and
/// reported through `onConnected`; cancel and failure leave the presenting
/// surface untouched.
struct AbilityConnectSheet: View {
    let ability: AbilitiesAPI.Ability
    /// Called with the refreshed ability (entitlement now active); the
    /// presenter dismisses and continues.
    let onConnected: (AbilitiesAPI.Ability) -> Void

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @State private var viewModel: AbilitiesListViewModel

    /// Takes the whole selection so the service and its authorizer are
    /// latched together for the sheet's lifetime (see `AbilitiesSelection`).
    init(
        ability: AbilitiesAPI.Ability,
        selection: AbilitiesSelection,
        onConnected: @escaping (AbilitiesAPI.Ability) -> Void
    ) {
        self.ability = ability
        self.onConnected = onConnected
        _viewModel = State(initialValue: AbilitiesListViewModel(service: selection.service, authorizer: selection.authorizer))
    }

    var body: some View {
        content
            .task { await viewModel.refresh() }
            .onChange(of: connectedAbility) { _, newValue in
                guard let newValue else { return }
                onConnected(newValue)
            }
    }

    /// The ability as served by the freshest catalog once its entitlement
    /// is active; nil until then. Flipping non-nil is the success signal,
    /// which also covers an ability that went active elsewhere while this
    /// sheet was opening.
    private var connectedAbility: AbilitiesAPI.Ability? {
        guard let refreshed = viewModel.catalog?.abilities.first(where: { $0.id == ability.id }),
              refreshed.entitlement?.status == .active else { return nil }
        return refreshed
    }

    @ViewBuilder
    private var content: some View {
        if let pending = viewModel.pendingAuthorization {
            mockAuthorizationContent(pending)
        } else {
            connectContent
        }
    }

    /// Mock mode's stand-in for the provider consent page, embedded inline
    /// in place of the confirm content. Approve runs the same completion
    /// lifecycle the abilities list drives; cancel abandons the whole flow.
    private func mockAuthorizationContent(_ context: AbilityAuthorizationContext) -> some View {
        AbilityAuthorizationSheet(
            context: context,
            onAuthorize: { viewModel.completeAuthorization(context) },
            onCancel: handleAuthorizationCancelled
        )
    }

    private var connectContent: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            header
            if let errorMessage = viewModel.errorMessage {
                errorLabel(errorMessage)
            }
            actionButtons
        }
        .padding(.top, DesignConstants.Spacing.step6x)
        .padding(.bottom, horizontalSizeClass == .regular ? DesignConstants.Spacing.step6x : 0)
        .accessibilityIdentifier("ability-connect-sheet")
    }

    private var header: some View {
        let displayName: String = ability.displayName.resolved()
        return VStack(spacing: DesignConstants.Spacing.step2x) {
            AbilityIconView(ability: ability)
            Text("Connect \(displayName)?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
            Text("You'll sign in with \(displayName), then pick what to share in this convo.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private func errorLabel(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.colorCaution)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private var actionButtons: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            connectButton
            cancelButton
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
    }

    private var connectButton: some View {
        let isBusy: Bool = viewModel.isBusy(ability)
        let title: String = viewModel.errorMessage == nil ? "Connect" : "Try Again"
        let connectAction = { viewModel.connect(ability) }
        return Button(action: connectAction) {
            connectButtonLabel(title: title, isBusy: isBusy)
        }
        .convosButtonStyle(.rounded(fullWidth: true))
        .disabled(isBusy)
        .accessibilityIdentifier("ability-connect-confirm-button")
    }

    @ViewBuilder
    private func connectButtonLabel(title: String, isBusy: Bool) -> some View {
        if isBusy {
            ProgressView()
        } else {
            Text(title)
        }
    }

    private var cancelButton: some View {
        let cancelAction = { dismiss() }
        return Button(action: cancelAction) {
            Text("Cancel")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignConstants.Spacing.step3x)
        }
        .accessibilityIdentifier("ability-connect-cancel-button")
    }

    /// Cancel from the mock authorization step: same outcome as Cancel on
    /// the confirm step. The entitlement stays pending server-side, so the
    /// presenting row keeps offering the connect path.
    private func handleAuthorizationCancelled() {
        viewModel.cancelAuthorization()
        dismiss()
    }
}

#Preview("Connect") {
    let youtube = MockAbilitiesService.standardCatalog().first { $0.id == "youtube" }
    if let youtube {
        AbilityConnectSheet(
            ability: youtube,
            selection: AbilitiesSelection(service: MockAbilitiesService()),
            onConnected: { _ in }
        )
    }
}
