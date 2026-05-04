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
        isDeleting = true
        deletionError = nil
        deletionProgress = nil
        Task { await runDeletion(onComplete: onComplete) }
    }

    private func resetLocalState() {
        Self.resetProfile()
        Self.resetGlobalDefaults()
        Self.resetConversationDefaults()
        Self.resetConversationsDefaults()
        Self.resetOnboardingDefaults()
    }

    private static func resetProfile() {
        ProfileSettingsViewModel.shared.delete()
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
