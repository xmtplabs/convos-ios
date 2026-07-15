import ConvosCore
import ConvosMetrics
import SwiftUI

/// Confirmation sheet for "Delete my account" (settings). Runs the real
/// account deletion: backend first while the identity keys still exist,
/// then the manifest-driven local wipe. Copy is deliberately honest about
/// what is and is not deleted; the subscription disclosure shows
/// universally because cached StoreKit state can be stale.
struct DeleteAccountView: View {
    @Environment(\.dismiss) var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @Bindable var viewModel: AppSettingsViewModel
    let onComplete: () -> Void
    @State private var navState: DeleteAllDataNavigatorImpl = .init()
    @State private var navigator: DeleteAllDataCollector?

    private func ensureNavigator() {
        guard navigator == nil else { return }
        navigator = DeleteAllDataCollector(
            instance: navState,
            delegate: PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        )
    }

    private var title: String {
        viewModel.hasPendingAccountDeletion ? "Finish deleting your account" : "Delete your account?"
    }

    private var subtitle: String {
        if viewModel.hasPendingAccountDeletion {
            return "An earlier deletion didn't finish. Hold to retry."
        }
        return "This permanently deletes your account and its data from Convos. It can't be undone."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text(title)
                .font(.system(.largeTitle))
                .fontWeight(.bold)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)

            disclosureList

            errorSection

            actionSection
        }
        .padding([.leading, .top, .trailing], DesignConstants.Spacing.step10x)
        .onAppear {
            ensureNavigator()
            navState.markScreenAppeared()
        }
        .onDisappear {
            navigator?.closed(context: navState.closeContext())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("delete-account-sheet")
    }

    // MARK: - Disclosure

    private var disclosureList: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            DisclosureRow(text: "Your account data is removed right away; anything left in storage is purged within 24 hours.")
            DisclosureRow(text: "Messages already delivered to other people and the messaging network can't be deleted.")
            DisclosureRow(text: "Your other devices stop working with this account; their local data stays until deleted there.")
            DisclosureRow(text: "Some payment records are kept in pseudonymized form where required.")
            subscriptionDisclosure
        }
    }

    private var subscriptionDisclosure: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
            DisclosureRow(text: "Deleting your account does not cancel any App Store subscription.")
            manageSubscriptionsLink
        }
    }

    private var manageSubscriptionsLink: some View {
        let action = {
            if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                openURL(url)
            }
        }
        return Button(action: action) {
            Text("Manage subscriptions")
                .font(.subheadline)
        }
        .convosButtonStyle(.text)
        .accessibilityIdentifier("manage-subscriptions-link")
    }

    // MARK: - Error / progress

    @ViewBuilder
    private var errorSection: some View {
        if let error = viewModel.deletionError {
            Text(Self.errorMessage(for: error))
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .padding(.vertical, DesignConstants.Spacing.stepX)
                .accessibilityIdentifier("delete-account-error")
        }
    }

    private static func errorMessage(for error: Error) -> String {
        switch error {
        case AccountDeletionError.identityUnavailable:
            return "This device can't read its account keys, so the account can't be deleted from here. Contact support."
        case AccountDeletionError.wipeIncomplete:
            return "Your account was deleted, but some local data couldn't be erased yet. Hold to retry, or it finishes on the next launch."
        case AccountDeletionError.preflightFailed:
            return "Couldn't reach the server, so nothing was deleted. Deleting your account requires a network connection - check it and try again."
        case AccountDeletionError.preflightFailedRecordHeld:
            return "Couldn't reach the server, so nothing was deleted. The pending state on this device couldn't be reset yet; it clears on the next launch, and nothing gets deleted unless you retry."
        case AccountDeletionError.displacedRecordUnresolved:
            return "A deletion started for a previous account on this device is still unconfirmed. Check your connection and try again."
        case AccountDeletionError.backendRequestFailed:
            return "Couldn't confirm the deletion with the server. Nothing was erased on this device - check your connection and try again."
        default:
            return "\(error.localizedDescription). Try again."
        }
    }

    private var progressText: String? {
        switch viewModel.accountDeletionProgress {
        case .requestingBackendDeletion:
            return "Deleting your account..."
        case .revokingDevices:
            return "Signing out your devices..."
        case .wipingLocalData:
            return "Erasing data on this device..."
        case .completed, nil:
            return nil
        }
    }

    // MARK: - Actions

    private var actionSection: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            HoldToDeleteAccountButton(
                isDeleting: viewModel.isDeleting,
                progressText: progressText,
                onDelete: { deleteAccount() }
            )
            .hoverEffect(.lift)

            cancelButton
        }
        .padding(.top, DesignConstants.Spacing.step4x)
    }

    private var cancelButton: some View {
        let action = { dismiss() }
        return Button(action: action) {
            Text("Cancel")
        }
        .convosButtonStyle(.text)
        .disabled(viewModel.isDeleting)
        .hoverEffect(.lift)
    }

    private func deleteAccount() {
        viewModel.deleteAccount(onComplete: onComplete)
    }
}

// MARK: - Disclosure Row

private struct DisclosureRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step2x) {
            Text("\u{2022}")
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
        }
    }
}

// MARK: - Hold To Delete Button

private struct HoldToDeleteAccountButton: View {
    let isDeleting: Bool
    let progressText: String?
    let onDelete: () -> Void

    private var buttonConfig: HoldToConfirmStyleConfig {
        var config = HoldToConfirmStyleConfig.default
        config.duration = 3.0
        config.backgroundColor = .colorCaution
        return config
    }

    var body: some View {
        let action = { onDelete() }
        let label: String = isDeleting ? "Deleting account" : "Hold to delete my account"
        let hint: String = isDeleting ? "" : "Hold to confirm account deletion"
        Button(action: action) {
            textView
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .disabled(isDeleting)
        .buttonStyle(HoldToConfirmPrimitiveStyle(config: buttonConfig))
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier("hold-to-delete-account-button")
    }

    private var textView: some View {
        let idleOpacity: Double = isDeleting ? 0 : 1
        let busyOpacity: Double = isDeleting ? 1 : 0
        return ZStack {
            Text("Hold to delete")
                .opacity(idleOpacity)

            Text(progressText ?? "Deleting...")
                .opacity(busyOpacity)
        }
        .animation(.easeInOut(duration: 0.2), value: isDeleting)
    }
}

#Preview {
    let viewModel = AppSettingsViewModel(session: ConvosClient.mock().session)
    DeleteAccountView(
        viewModel: viewModel,
        onComplete: {}
    )
}
