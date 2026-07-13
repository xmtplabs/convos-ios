import Foundation
import GRDB

/// The set of conversations this device's user has allowed, mirrored into
/// the device-local keychain so it survives app deletion (the consent
/// records themselves live in the app container's database and do not).
///
/// Consent cannot be recovered from the network after a reinstall: XMTP
/// propagates consent records as messages inside the device-sync MLS
/// group, which a new installation cannot decrypt (they predate its
/// membership), and the only installation that could re-send them died
/// with the deleted app container. Without this backup, conversations
/// recovered by re-welcome land as consent=unknown and never surface in
/// the UI. Restoring from the backup is spam-safe: it re-allows exactly
/// the conversations this device's user had allowed, nothing else.
public struct ConsentBackup: Codable, Sendable, Equatable {
    public let inboxId: String
    public let allowedConversationIds: [String]

    public init(inboxId: String, allowedConversationIds: [String]) {
        self.inboxId = inboxId
        self.allowedConversationIds = allowedConversationIds
    }
}

extension ConsentBackup {
    /// The ids worth backing up: every non-draft conversation the user has
    /// allowed. Drafts are client-local placeholders that don't exist on
    /// the network, so restoring consent for them is meaningless. Sorted
    /// so snapshots compare stably. Static and pure for unit testing.
    static func allowedConversationIds(db: Database) throws -> [String] {
        let ids = try DBConversation
            .filter(DBConversation.Columns.consent == Consent.allowed)
            .select(DBConversation.Columns.id, as: String.self)
            .fetchAll(db)
        return ids
            .filter { !DBConversation.isDraft(id: $0) }
            .sorted()
    }
}

/// Restore helpers for backed-up consent after a reinstall resume,
/// invoked from the stale-installation reconcile (the reliable reinstall
/// signal: same inbox, different installation id). Split into Sendable-
/// only helpers because the XMTP client is not Sendable and must stay in
/// the caller's actor region - the caller sequences: load ids here, apply
/// them via `client.setConsentStates`, then flip stored rows here. The
/// keychain backup is never consumed by a restore attempt.
enum ConsentBackupRestorer {
    /// The backed-up allowed conversation ids applicable to `inboxId`,
    /// empty when there is no backup, the backup belongs to a replaced
    /// identity, or nothing was allowed.
    static func idsToRestore(
        identityStore: any KeychainIdentityStoreProtocol,
        inboxId: String
    ) async throws -> [String] {
        guard let backup = try await identityStore.loadConsentBackup(),
              backup.inboxId == inboxId else {
            return []
        }
        return backup.allowedConversationIds
    }

    /// Flips already-stored rows for the restored ids from `.unknown` to
    /// `.allowed` so the list updates without waiting for a re-sync.
    /// Rows in other states are left alone - `.denied` means the user
    /// deleted the conversation and it must stay hidden. Rows that don't
    /// exist yet need nothing: their welcomes land already-allowed via
    /// the consent records written before this.
    static func flipStoredUnknownRows(
        ids: [String],
        databaseWriter: any DatabaseWriter
    ) async throws {
        guard !ids.isEmpty else { return }
        try await databaseWriter.write { db in
            let stored = try DBConversation
                .filter(ids.contains(DBConversation.Columns.id))
                .filter(DBConversation.Columns.consent == Consent.unknown)
                .fetchAll(db)
            for conversation in stored {
                try conversation.with(consent: .allowed).save(db)
            }
        }
    }
}
