import ConvosCore
import Foundation

extension ConversationsViewModel {
    static let skippedRestoreBackupDateKey: String = "skippedRestoreBackupDate"

    /// Probes for a restorable backup. Called from `.onAppear` and on
    /// `didBecomeActive` (to handle iCloud Keychain sync lag on fresh
    /// install). Populates `availableRestorePrompt` on the main actor;
    /// FileManager work runs in a detached `Task` so a slow ubiquity
    /// container lookup doesn't block the UI.
    func checkForAvailableBackup() {
        guard availableRestorePrompt == nil else { return }
        guard !hasAnyUsedNonVaultInbox() else { return }

        let environment = self.environment
        let skippedDate = Self.skippedRestoreDate()
        Task.detached(priority: .utility) { [weak self] in
            let result = RestoreManager.findAvailableBackup(environment: environment)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.availableRestorePrompt == nil else { return }
                guard !self.hasAnyUsedNonVaultInbox() else { return }
                guard let metadata = result?.metadata else { return }
                if let skipped = skippedDate, metadata.createdAt <= skipped { return }
                self.availableRestorePrompt = metadata
                QAEvent.emit(.backup, "restore_prompt_shown", [
                    "device": metadata.deviceName,
                    "inbox_count": String(metadata.inboxCount)
                ])
            }
        }
    }

    func onRestorePromptTapped() {
        presentingRestoreSheet = true
        QAEvent.emit(.backup, "restore_prompt_tapped")
    }

    func skipRestorePrompt() {
        guard let metadata = availableRestorePrompt else { return }
        Self.persistSkippedRestoreDate(metadata.createdAt)
        availableRestorePrompt = nil
        QAEvent.emit(.backup, "restore_prompt_skipped")
    }

    func clearRestorePromptAfterRestore() {
        availableRestorePrompt = nil
        presentingRestoreSheet = false
    }

    private func hasAnyUsedNonVaultInbox() -> Bool {
        let repo = InboxesRepository(databaseReader: session.databaseReader)
        return ((try? repo.nonVaultUsedInboxes().count) ?? 0) > 0
    }

    static func skippedRestoreDate() -> Date? {
        guard let value = UserDefaults.standard.string(forKey: skippedRestoreBackupDateKey) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)
    }

    static func persistSkippedRestoreDate(_ date: Date) {
        let formatter = ISO8601DateFormatter()
        UserDefaults.standard.set(formatter.string(from: date), forKey: skippedRestoreBackupDateKey)
    }
}
