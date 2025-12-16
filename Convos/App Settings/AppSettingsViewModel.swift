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

    init(session: any SessionManagerProtocol) {
        self.session = session
    }

    // MARK: - Actions

    func deleteAllData(onComplete: @escaping () -> Void) {
        guard !isDeleting else { return }
        isDeleting = true
        deletionError = nil
        deletionProgress = nil

        QuicknameSettingsViewModel.shared.delete()

        Task {
            do {
                for try await progress in session.deleteAllInboxesWithProgress() {
                    deletionProgress = progress
                }
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
