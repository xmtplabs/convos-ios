import Foundation

/// A device identity found in the iCloud-synced keychain backup slot that
/// doesn't match this install's identity - i.e. another device on the same
/// iCloud account the user can pair with. Carries only display metadata;
/// the backup's key material stays inside ConvosCore
/// (`SessionManager.pairingInviteSlug(forBackupInboxId:expiresAt:)` signs
/// with it on demand).
public struct PairableDeviceBackup: Sendable, Equatable, Identifiable {
    public let inboxId: String
    public let deviceName: String?
    public let backedUpAt: Date?

    public var id: String { inboxId }

    public init(inboxId: String, deviceName: String?, backedUpAt: Date?) {
        self.inboxId = inboxId
        self.deviceName = deviceName
        self.backedUpAt = backedUpAt
    }
}

/// Everything the Devices screen needs from the iCloud-synced backup
/// slot: the current identity's own mirror, every other identity's
/// backup, and which of them is the "main" device - the identity whose
/// key was created first. `backedUpAt` is the best available proxy for
/// key creation (a mirror is written when the identity is saved; pairing
/// re-saves and late backfills can re-stamp it, the same caveat the
/// prompt's ordering rule carries).
///
/// Unlike `PairableDeviceBackup.pairableBackups`, `otherDevices` is not
/// filtered by the newer-than-own ordering rule: that rule exists so the
/// unsolicited first-install prompt never offers a device demotion,
/// whereas the Devices screen is an explicit, user-navigated inventory
/// of every key on the iCloud account.
public struct ICloudDeviceBackupsSnapshot: Sendable, Equatable {
    /// The current identity's own mirror, nil when it hasn't been
    /// written yet (or the keychain read failed upstream).
    public let currentDevice: PairableDeviceBackup?
    /// Every other identity's backup, oldest first.
    public let otherDevices: [PairableDeviceBackup]

    /// The inboxId of the oldest key on the iCloud account, nil when no
    /// key carries a timestamp to order by.
    public var mainDeviceInboxId: String? {
        let candidates = ([currentDevice].compactMap { $0 } + otherDevices)
            .filter { $0.backedUpAt != nil }
        let oldest = candidates.min { (lhs: PairableDeviceBackup, rhs: PairableDeviceBackup) -> Bool in
            (lhs.backedUpAt ?? .distantFuture, lhs.inboxId) < (rhs.backedUpAt ?? .distantFuture, rhs.inboxId)
        }
        return oldest?.inboxId
    }

    /// Whether the current identity holds the account's main (oldest)
    /// key. False when ordering can't be established.
    public var currentDeviceIsMain: Bool {
        guard let currentDevice else { return false }
        return mainDeviceInboxId == currentDevice.inboxId
    }

    public init(currentDevice: PairableDeviceBackup?, otherDevices: [PairableDeviceBackup]) {
        self.currentDevice = currentDevice
        self.otherDevices = otherDevices
    }
}

extension ICloudDeviceBackupsSnapshot {
    /// Builds the snapshot from raw synced backups. Static and pure so
    /// it can be unit tested without a keychain. A nil `currentInboxId`
    /// (no identity yet) leaves `currentDevice` nil and treats every
    /// backup as another device's.
    static func snapshot(
        from backups: [KeychainIdentityBackup],
        currentInboxId: String?
    ) -> ICloudDeviceBackupsSnapshot {
        let own = backups
            .first { $0.inboxId == currentInboxId }
            .map { (backup: KeychainIdentityBackup) -> PairableDeviceBackup in
                PairableDeviceBackup(
                    inboxId: backup.inboxId,
                    deviceName: backup.deviceName,
                    backedUpAt: backup.backedUpAt
                )
            }
        let others = backups
            .filter { $0.inboxId != currentInboxId }
            .map { (backup: KeychainIdentityBackup) -> PairableDeviceBackup in
                PairableDeviceBackup(
                    inboxId: backup.inboxId,
                    deviceName: backup.deviceName,
                    backedUpAt: backup.backedUpAt
                )
            }
            .sorted { (lhs: PairableDeviceBackup, rhs: PairableDeviceBackup) -> Bool in
                (lhs.backedUpAt ?? .distantFuture, lhs.inboxId) < (rhs.backedUpAt ?? .distantFuture, rhs.inboxId)
            }
        return ICloudDeviceBackupsSnapshot(currentDevice: own, otherDevices: others)
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
