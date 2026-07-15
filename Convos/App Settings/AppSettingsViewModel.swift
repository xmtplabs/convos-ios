import ConvosCore
import Foundation
import Observation

@MainActor
@Observable
final class AppSettingsViewModel {
    // MARK: - State

    private(set) var isDeleting: Bool = false
    private(set) var deletionProgress: InboxDeletionProgress?
    private(set) var deletionError: Error?
    private(set) var accountDeletionProgress: AccountDeletionProgress?

    /// True when a durable deletion record is pending resolution (an
    /// earlier attempt sent the request but never got a confirmed
    /// outcome, or a wipe is unfinished). The settings row surfaces a
    /// retry in this state.
    var hasPendingAccountDeletion: Bool {
        session.accountDeletionStatus().blocksIdentityProvisioning
    }

    // MARK: - Dependencies

    private let session: any SessionManagerProtocol
    let connectionsListViewModel: ConnectionsListViewModel

    init(session: any SessionManagerProtocol) {
        self.session = session

        let callbackScheme = ConfigManager.shared.appUrlScheme

        let manager = session.cloudConnectionManager(
            callbackURLScheme: callbackScheme
        )
        let repository = session.cloudConnectionRepository()

        self.connectionsListViewModel = ConnectionsListViewModel(
            cloudConnectionManager: manager,
            cloudConnectionRepository: repository,
            deviceConnectionAuthorizer: session.deviceConnectionAuthorizer()
        )
    }

    // MARK: - Actions

    func deleteAllData(onComplete: @escaping () -> Void) {
        guard !isDeleting else { return }
        prepareForDeletion()
        Task { await runDeletion(onComplete: onComplete) }
    }

    /// Deletes the account for real: backend deletion first (keys intact),
    /// then the manifest-driven local wipe. Distinct from `deleteAllData`,
    /// which is a local reset that leaves the backend account alive.
    func deleteAccount(onComplete: @escaping () -> Void) {
        guard !isDeleting else { return }
        prepareForDeletion()
        Task { await runAccountDeletion(onComplete: onComplete) }
    }

    private func runAccountDeletion(onComplete: @escaping () -> Void) async {
        do {
            for try await progress in session.deleteAccountWithProgress() {
                accountDeletionProgress = progress
            }
            // The wipe manifest cleared persisted state; this rebinds the
            // in-memory singletons (profile writer, cached view-model
            // state) so the running process matches the wiped disk.
            resetLocalState()
            isDeleting = false
            onComplete()
        } catch {
            deletionError = error
            isDeleting = false
        }
    }

    private func prepareForDeletion() {
        isDeleting = true
        deletionError = nil
        deletionProgress = nil
        accountDeletionProgress = nil
    }

    private func resetLocalState() {
        Self.resetProfile(session: session)
        Self.resetGlobalDefaults()
        Self.resetConversationDefaults()
        Self.resetConversationsDefaults()
        Self.resetOnboardingDefaults()
    }

    // The profile singleton holds a writer bound to the old inbox. Delete-all
    // registers a fresh inbox, so we rebind to point it at the new one;
    // otherwise a later "My Info" save targets the dead inbox and never reaches
    // new conversations. rebind also clears the editing fields
    private static func resetProfile(session: any SessionManagerProtocol) {
        ProfileSettingsViewModel.shared.rebind(session: session)
    }

    private static func resetGlobalDefaults() {
        GlobalConvoDefaults.shared.reset()
    }

    private static func resetConversationDefaults() {
        ConversationViewModel.resetUserDefaults()
    }

    private static func resetConversationsDefaults() {
        ConversationsViewModel.resetUserDefaults()
    }

    private static func resetOnboardingDefaults() {
        ConversationOnboardingCoordinator.resetUserDefaults()
    }

    private func runDeletion(onComplete: @escaping () -> Void) async {
        do {
            for try await progress in session.deleteAllInboxesWithProgress() {
                deletionProgress = progress
            }
            // Wipe local UI state only after the on-disk deletion succeeded — otherwise
            // a failure mid-stream would leave settings appearing reset while the
            // underlying inboxes are still on device.
            resetLocalState()
            isDeleting = false
            onComplete()
        } catch {
            deletionError = error
            isDeleting = false
        }
    }
}

extension AppSettingsViewModel {
    static var mock: AppSettingsViewModel {
        AppSettingsViewModel(session: MockInboxesService())
    }
}
