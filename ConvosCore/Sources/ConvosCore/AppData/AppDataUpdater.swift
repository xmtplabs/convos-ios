import ConvosAppData
import Foundation

/// The merge rule for one `AppDataDomain`: transplant only that domain's
/// sub-field from the persisted local snapshot into the fresh network blob,
/// carrying everything else from the network unchanged.
///
/// Must be a stateless, deterministic pure function - it is re-run on every
/// reconcile pass, and running it against the re-read blob is also the "landed"
/// check (a row is verified published exactly when re-applying its intent is a
/// no-op). Any randomness was already frozen into the snapshot at enqueue.
protocol AppDataUpdater: Sendable {
    var domain: AppDataDomain { get }
    func onAppDataMerge(
        conversationId: String,
        scopeKey: String?,
        current: ConversationCustomMetadata,
        previousChanged: ConversationCustomMetadata
    ) -> ConversationCustomMetadata
}

/// Carries the snapshot's tag over the network value. Ensure, rotate, and
/// restore all reduce to this - the enqueue-time closure decided the value.
struct InviteTagUpdater: AppDataUpdater {
    let domain: AppDataDomain = .inviteTag

    func onAppDataMerge(
        conversationId: String,
        scopeKey: String?,
        current: ConversationCustomMetadata,
        previousChanged: ConversationCustomMetadata
    ) -> ConversationCustomMetadata {
        var merged = current
        if !previousChanged.tag.isEmpty {
            merged.tag = previousChanged.tag
        }
        return merged
    }
}

/// Transplants one inbox's profile entry (the scope key) from the snapshot;
/// every other member's entry rides the fresh blob. A snapshot entry with
/// cleared image fields transplants as cleared (avatar removal).
struct ProfileUpdater: AppDataUpdater {
    let domain: AppDataDomain = .profile

    func onAppDataMerge(
        conversationId: String,
        scopeKey: String?,
        current: ConversationCustomMetadata,
        previousChanged: ConversationCustomMetadata
    ) -> ConversationCustomMetadata {
        guard let scopeKey, let snapshotProfile = previousChanged.findProfile(inboxId: scopeKey) else {
            return current
        }
        var merged = current
        merged.upsertProfile(snapshotProfile)
        return merged
    }
}

/// Carries the snapshot's participation mode; last local intent wins over the
/// network value until it lands.
struct ParticipationUpdater: AppDataUpdater {
    let domain: AppDataDomain = .participation

    func onAppDataMerge(
        conversationId: String,
        scopeKey: String?,
        current: ConversationCustomMetadata,
        previousChanged: ConversationCustomMetadata
    ) -> ConversationCustomMetadata {
        var merged = current
        if previousChanged.hasParticipationMode {
            merged.participationMode = previousChanged.participationMode
        }
        return merged
    }
}

/// Carries the snapshot's expiry timestamp.
struct ExpiryUpdater: AppDataUpdater {
    let domain: AppDataDomain = .expiry

    func onAppDataMerge(
        conversationId: String,
        scopeKey: String?,
        current: ConversationCustomMetadata,
        previousChanged: ConversationCustomMetadata
    ) -> ConversationCustomMetadata {
        var merged = current
        if previousChanged.hasExpiresAtUnix {
            merged.expiresAtUnix = previousChanged.expiresAtUnix
        }
        return merged
    }
}

/// Ensure-if-absent: a peer's concurrently-set emoji on the network wins, and
/// the pending row then self-clears because re-applying it is a no-op.
struct EmojiUpdater: AppDataUpdater {
    let domain: AppDataDomain = .emoji

    func onAppDataMerge(
        conversationId: String,
        scopeKey: String?,
        current: ConversationCustomMetadata,
        previousChanged: ConversationCustomMetadata
    ) -> ConversationCustomMetadata {
        guard !current.hasEmoji || current.emoji.isEmpty else { return current }
        guard previousChanged.hasEmoji, !previousChanged.emoji.isEmpty else { return current }
        var merged = current
        merged.emoji = previousChanged.emoji
        return merged
    }
}

/// Write-once agent-DM marker: once the network carries one (possibly enriched
/// by the server), the local stamp never overwrites it.
struct AgentDmUpdater: AppDataUpdater {
    let domain: AppDataDomain = .agentDm

    func onAppDataMerge(
        conversationId: String,
        scopeKey: String?,
        current: ConversationCustomMetadata,
        previousChanged: ConversationCustomMetadata
    ) -> ConversationCustomMetadata {
        guard previousChanged.hasAgentDm, !current.hasAgentDm else { return current }
        var merged = current
        merged.agentDm = previousChanged.agentDm
        return merged
    }
}

/// Clears a legacy encrypted group-image ref whenever the network still
/// carries one. Once the network blob has no ref the intent is landed.
struct LegacyImageCleanupUpdater: AppDataUpdater {
    let domain: AppDataDomain = .legacyImageCleanup

    func onAppDataMerge(
        conversationId: String,
        scopeKey: String?,
        current: ConversationCustomMetadata,
        previousChanged: ConversationCustomMetadata
    ) -> ConversationCustomMetadata {
        guard current.hasEncryptedGroupImage else { return current }
        var merged = current
        merged.clearEncryptedGroupImage()
        return merged
    }
}

extension [AppDataDomain: any AppDataUpdater] {
    /// The production registry: one updater per writable domain.
    static var standard: [AppDataDomain: any AppDataUpdater] {
        let updaters: [any AppDataUpdater] = [
            InviteTagUpdater(),
            ProfileUpdater(),
            ParticipationUpdater(),
            ExpiryUpdater(),
            EmojiUpdater(),
            AgentDmUpdater(),
            LegacyImageCleanupUpdater(),
        ]
        return Dictionary(uniqueKeysWithValues: updaters.map { ($0.domain, $0) })
    }
}
