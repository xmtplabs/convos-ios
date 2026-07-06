import Foundation

/// A device identity found in the iCloud-synced keychain backup slot that
/// doesn't match this install's identity - i.e. another device on the same
/// iCloud account the user can pair with. Carries only display metadata;
/// the backup's key material stays inside ConvosCore
/// (`SessionManager.pairingInviteSlug(forBackupInboxId:expiresAt:)` signs
/// with it on demand).
public struct PairableDeviceBackup: Sendable, Equatable {
    public let inboxId: String
    public let deviceName: String?
    public let backedUpAt: Date?

    public init(inboxId: String, deviceName: String?, backedUpAt: Date?) {
        self.inboxId = inboxId
        self.deviceName = deviceName
        self.backedUpAt = backedUpAt
    }
}

extension PairableDeviceBackup {
    /// Filters raw synced backups down to identities other than
    /// `currentInboxId` (a fresh install's own placeholder identity mirrors
    /// itself into the backup slot, so the current identity is usually
    /// present too), newest backup first. Static and pure so it can be
    /// unit tested without a keychain.
    static func pairableBackups(
        from backups: [KeychainIdentityBackup],
        excludingInboxId currentInboxId: String?
    ) -> [PairableDeviceBackup] {
        // A nil current identity means the keychain read failed, not that
        // there is nothing to exclude - without the exclusion this
        // install's own backup would surface in the "Pair <device>?"
        // prompt and offer a self-pair. Hide the prompt until the
        // identity read succeeds (the check re-runs on next activation).
        guard let currentInboxId else { return [] }
        return backups
            .filter { $0.inboxId != currentInboxId }
            .map { (backup: KeychainIdentityBackup) -> PairableDeviceBackup in
                PairableDeviceBackup(
                    inboxId: backup.inboxId,
                    deviceName: backup.deviceName,
                    backedUpAt: backup.backedUpAt
                )
            }
            .sorted { ($0.backedUpAt ?? .distantPast) > ($1.backedUpAt ?? .distantPast) }
    }
}
