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
        isDeleting = true
        deletionError = nil
        deletionProgress = nil

        Task {
            do {
                for try await progress in session.deleteAllInboxesWithProgress() {
                    deletionProgress = progress
                }

                // Deletion complete
                isDeleting = false
                onComplete()
            } catch {
                deletionError = error
                isDeleting = false
            }
        }
    }
}
