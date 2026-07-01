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
/// Not wired into startup yet; the lifecycle PR calls `run()`.
struct ProfileBackfill {
    private let databaseReader: any DatabaseReader
    private let profileStore: any ProfileStoreProtocol
    private let selfProfileStore: any SelfProfileStoreProtocol
    private let selfInboxId: String

    /// Floor timestamp for backfilled rows; any real event (later `sentAt`)
    /// supersedes them.
    private let floor: Date = .init(timeIntervalSince1970: 0)

    init(
        databaseReader: any DatabaseReader,
        profileStore: any ProfileStoreProtocol,
        selfProfileStore: any SelfProfileStoreProtocol,
        selfInboxId: String
    ) {
        self.databaseReader = databaseReader
        self.profileStore = profileStore
        self.selfProfileStore = selfProfileStore
        self.selfInboxId = selfInboxId
    }

    func run() async throws {
        let rows = try await databaseReader.read { db in
            try DBMemberProfile.fetchAll(db)
        }
        guard !rows.isEmpty else { return }

        // Collapse a person's multiple conversation rows into one identity, and
        // gather the current user's own name/metadata for the self seed.
        var identityByInbox: [String: DBProfile] = [:]
        var selfName: String?
        var selfMetadata: ProfileMetadata?
        var sawSelf = false

        for row in rows {
            if row.inboxId == selfInboxId {
                sawSelf = true
                if selfName == nil {
                    selfName = ProfileMerge.nonBlank(row.name)
                }
                if selfMetadata == nil {
                    selfMetadata = row.metadata
                }
            } else {
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

        if sawSelf, try await selfProfileStore.load() == nil {
            try await selfProfileStore.save(
                DBSelfProfile(inboxId: selfInboxId, name: selfName, metadata: selfMetadata, updatedAt: floor)
            )
        }
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
        if let merged {
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
            try await profileStore.saveIdentity(merged)
        }
    }
}
