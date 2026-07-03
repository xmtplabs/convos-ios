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
    func mirror(_ rows: [DBMemberProfile]) async throws {
        guard !rows.isEmpty else { return }

        // Collapse a person's multiple conversation rows into one identity. Self
        // identity lives in `myProfile`, so self rows are skipped here; their
        // avatars are still backfilled below.
        var identityByInbox: [String: DBProfile] = [:]
        for row in rows {
            if row.inboxId != selfInboxId {
                identityByInbox[row.inboxId] = ProfileMerge.mergeIdentity(
                    existing: identityByInbox[row.inboxId],
                    inboxId: row.inboxId,
                    incoming: IncomingIdentity(name: row.name, memberKind: row.memberKind, metadata: row.metadata),
                    source: .contact,
                    sentAt: floor
                )
            }
            try await backfillAvatar(row)
        }

        try await backfillIdentities(identityByInbox)
    }

    private func backfillAvatar(_ row: DBMemberProfile) async throws {
        guard row.hasValidEncryptedAvatar, let url = row.avatar else { return }
        let existing = try await profileStore.avatar(inboxId: row.inboxId, conversationId: row.conversationId)
        let merged = ProfileMerge.mergeAvatar(
            existing: existing,
            inboxId: row.inboxId,
            conversationId: row.conversationId,
            incoming: .set(url: url, salt: row.avatarSalt, nonce: row.avatarNonce, key: row.avatarKey),
            source: .contact,
            sentAt: floor
        )
        if let merged, merged != existing {
            try await profileStore.saveAvatar(merged)
        }
    }

    private func backfillIdentities(_ identityByInbox: [String: DBProfile]) async throws {
        for (inboxId, accumulated) in identityByInbox {
            // Merge against whatever is already stored at `.contact`/floor, so a
            // value already set by a real event is preserved, not overwritten.
            let existing = try await profileStore.identity(inboxId: inboxId)
            let merged = ProfileMerge.mergeIdentity(
                existing: existing,
                inboxId: inboxId,
                incoming: IncomingIdentity(name: accumulated.name, memberKind: accumulated.memberKind, metadata: accumulated.metadata),
                source: .contact,
                sentAt: floor
            )
            if merged != existing {
                try await profileStore.saveIdentity(merged)
            }
        }
    }
}
