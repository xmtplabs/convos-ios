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
            cloudConnectionRepository: repository
        )
    }

    // MARK: - Actions

    func deleteAllData(onComplete: @escaping () -> Void) {
        guard !isDeleting else { return }
        isDeleting = true
        deletionError = nil
        deletionProgress = nil

        resetUserDefaultsForDeletion()
        runInboxDeletion(onComplete: onComplete)
    }

    // Each reset is dispatched individually to keep the type-checker
    // under the project's 100ms warn-long-function-bodies budget.
    // Bundling them into one function pushes the inferred Sendable
    // captures across the @MainActor boundary over the limit on some
    // build configurations.
    private func resetQuicknameDefaults() {
        QuicknameSettingsViewModel.shared.delete()
    }

    private func resetConversationDefaults() {
        ConversationViewModel.resetUserDefaults()
    }

    private func resetConversationsListDefaults() {
        ConversationsViewModel.resetUserDefaults()
    }

    private func resetConversationOnboardingDefaults() {
        ConversationOnboardingCoordinator.resetUserDefaults()
    }

    private func resetGlobalConvoDefaults() {
        GlobalConvoDefaults.shared.reset()
    }

    private func resetUserDefaultsForDeletion() {
        resetQuicknameDefaults()
        resetConversationDefaults()
        resetConversationsListDefaults()
        resetConversationOnboardingDefaults()
        resetGlobalConvoDefaults()
    }

    private func runInboxDeletion(onComplete: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stream = self.session.deleteAllInboxesWithProgress()
                for try await progress in stream {
                    self.deletionProgress = progress
                }
                self.isDeleting = false
                onComplete()
            } catch {
                self.deletionError = error
                self.isDeleting = false
            }
        }
    }
}

extension AppSettingsViewModel {
    static var mock: AppSettingsViewModel {
        AppSettingsViewModel(session: MockInboxesService())
    }
}
