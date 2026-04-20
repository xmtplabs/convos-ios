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

    init(session: any SessionManagerProtocol,
         connectionManager: (any ConnectionManagerProtocol)? = nil,
         connectionRepository: (any ConnectionRepositoryProtocol)? = nil) {
        self.session = session
        if let connectionManager, let connectionRepository {
            self.connectionsListViewModel = ConnectionsListViewModel(
                connectionManager: connectionManager,
                connectionRepository: connectionRepository
            )
        } else {
            self.connectionsListViewModel = ConnectionsListViewModel(
                connectionManager: MockConnectionManager(),
                connectionRepository: MockConnectionRepository()
            )
        }
    }

    // MARK: - Actions

    func deleteAllData(onComplete: @escaping () -> Void) {
        guard !isDeleting else { return }
        isDeleting = true
        deletionError = nil
        deletionProgress = nil

        QuicknameSettingsViewModel.shared.delete()
        ConversationViewModel.resetUserDefaults()
        ConversationsViewModel.resetUserDefaults()
        ConversationOnboardingCoordinator.resetUserDefaults()
        GlobalConvoDefaults.shared.reset()

        Task {
            do {
                for try await progress in session.deleteAllInboxesWithProgress() {
                    deletionProgress = progress
                }
                isDeleting = false
                onComplete()
            } catch {
                deletionError = error
                isDeleting = false
            }
        }
    }
}

extension AppSettingsViewModel {
    static var mock: AppSettingsViewModel {
        AppSettingsViewModel(session: MockInboxesService())
    }
}
