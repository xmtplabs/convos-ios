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
    ///
    /// A nil `currentInboxId` means the primary slot is empty - a true
    /// first launch checking before silent identity registration has
    /// completed - so there is nothing to exclude and every backup is
    /// pairable. This cannot leak the install's own backup as a
    /// self-pair: a backup mirror is only ever written after its primary,
    /// and callers read the backups before the primary slot, so an own
    /// mirror in `backups` implies the primary read that follows sees a
    /// non-nil identity. Callers whose primary read fails (throws, as
    /// opposed to returning nil) must not call this with nil - they
    /// can't tell whether an own backup is present and should hide the
    /// prompt until a later check succeeds.
    ///
    /// Backups written after this install's own key are also excluded:
    /// the "Pair <device>?" prompt exists to recover an identity that
    /// predates this install, and a newer backup means the other device
    /// was set up after this one (installing on a second device must not
    /// make the first device offer to demote itself to that newer
    /// identity). The install's own mirror in `backups` is the reference
    /// clock - it was stamped when this install's identity was saved.
    /// When ordering can't be established (no own mirror yet, or either
    /// side missing a timestamp) the backup stays pairable.
    static func pairableBackups(
        from backups: [KeychainIdentityBackup],
        excludingInboxId currentInboxId: String?
    ) -> [PairableDeviceBackup] {
        let ownBackedUpAt: Date? = backups
            .first { $0.inboxId == currentInboxId }?
            .backedUpAt
        return backups
            .filter { $0.inboxId != currentInboxId }
            .filter { (backup: KeychainIdentityBackup) -> Bool in
                guard let ownBackedUpAt, let backedUpAt = backup.backedUpAt else { return true }
                return backedUpAt <= ownBackedUpAt
            }
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
