import Foundation
import GRDB

/// One-time migration that seeds the canonical profile stores from the legacy
/// per-conversation `DBMemberProfile` rows. Runs at startup before
/// `ProfilesRepository.warmUp`, so the new tables are populated before any
/// reader fetches.
///
/// Everything is written at the lowest source (`.contact`) and an epoch-floor
/// timestamp, so any real inbound event supersedes a backfilled value. Idempotent
/// and non-clobbering: re-running fills only blanks of whatever is already there,
/// and a value already set by a real `profileUpdate` is never downgraded.
///
/// Only other members are migrated into `DBProfile`. The current user's own
/// identity lives in `myProfile` (written by the "My Info" editor), so self rows
/// are skipped for identity; their legacy avatars are still mirrored into
/// `DBProfileAvatar`.
///
/// Runs once at startup. Inbound profile events no longer flow through here -
/// they write the canonical stores directly via `ProfileInboundApplier` - so
/// this only migrates rows that predate the direct seam.
struct ProfileBackfill {
    private let databaseReader: any DatabaseReader
    private let profileStore: any ProfileStoreProtocol
    private let selfInboxId: String

    /// Floor timestamp for backfilled rows; any real event (later `sentAt`)
    /// supersedes them.
    private let floor: Date = .init(timeIntervalSince1970: 0)

    init(
        databaseReader: any DatabaseReader,
        profileStore: any ProfileStoreProtocol,
        selfInboxId: String
    ) {
        self.databaseReader = databaseReader
        self.profileStore = profileStore
        self.selfInboxId = selfInboxId
    }

    func run() async throws {
        let rows = try await databaseReader.read { db in
            try DBMemberProfile.fetchAll(db)
        }
        try await mirror(rows)
    }

    /// Mirrors the given legacy rows into the canonical stores. Idempotent: a
    /// write only happens when the merged value differs from what's stored, so a
    /// re-run does not churn writes for unchanged rows.
    ///
    /// Batched: everything the merges need is fetched in two reads, the merges
    /// run in memory, and the changed rows are written in one batch per table.
    /// The previous per-row store round-trips made every launch pay hundreds of
    /// sequential transactions on a large account (delaying `warmUp` and the
    /// publisher bind behind them), and a single bad avatar row aborted the
    /// identity backfill entirely; batch saves isolate per-row failures.
    func mirror(_ rows: [DBMemberProfile]) async throws {
        guard !rows.isEmpty else { return }

        let storedIdentities = try await profileStore.allIdentities()
        let storedAvatars = try await profileStore.allAvatars()
        var identityByInbox: [String: DBProfile] = [:]
        for identity in storedIdentities {
            identityByInbox[identity.inboxId] = identity
        }
        var avatarByKey: [String: DBProfileAvatar] = [:]
        for avatar in storedAvatars {
            avatarByKey[Self.avatarKey(avatar.inboxId, avatar.conversationId)] = avatar
        }

        // Collapse a person's multiple conversation rows into one identity,
        // merging directly over whatever is stored so a value already set by a
        // real event is preserved, not overwritten. Self identity lives in
        // `myProfile`, so self rows are skipped here; their avatars are still
        // backfilled below.
        var changedIdentities: [String: DBProfile] = [:]
        var changedAvatars: [String: DBProfileAvatar] = [:]
        for row in rows {
            if row.inboxId != selfInboxId {
                let existing = identityByInbox[row.inboxId]
                let merged = ProfileMerge.mergeIdentity(
                    existing: existing,
                    inboxId: row.inboxId,
                    incoming: IncomingIdentity(name: row.name, memberKind: row.memberKind, metadata: row.metadata),
                    source: .contact,
                    sentAt: floor
                )
                if merged != existing {
                    identityByInbox[row.inboxId] = merged
                    changedIdentities[row.inboxId] = merged
                }
            }

            guard row.hasValidEncryptedAvatar, let url = row.avatar else { continue }
            let key = Self.avatarKey(row.inboxId, row.conversationId)
            let existingAvatar = avatarByKey[key]
            let mergedAvatar = ProfileMerge.mergeAvatar(
                existing: existingAvatar,
                inboxId: row.inboxId,
                conversationId: row.conversationId,
                incoming: .set(url: url, salt: row.avatarSalt, nonce: row.avatarNonce, key: row.avatarKey),
                source: .contact,
                sentAt: floor
            )
            if let mergedAvatar, mergedAvatar != existingAvatar {
                avatarByKey[key] = mergedAvatar
                changedAvatars[key] = mergedAvatar
            }
        }

        try await profileStore.saveIdentities(Array(changedIdentities.values))
        try await profileStore.saveAvatars(Array(changedAvatars.values))
    }

    private static func avatarKey(_ inboxId: String, _ conversationId: String) -> String {
        "\(inboxId)|\(conversationId)"
    }
}
