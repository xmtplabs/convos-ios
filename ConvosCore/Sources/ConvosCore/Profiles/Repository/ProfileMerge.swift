import Foundation

/// Pure merge rules for inbound identity and avatar updates. No I/O; the
/// repository calls these and persists the result. Combines two axes:
///
/// - Precedence: a higher `ProfileSource` always wins; within the same source,
///   a strictly newer `sentAt` wins (equal time wins only for the local mirror
///   tiers on identity - see `winsOver`); a lower source only fills blanks.
/// - Guards: an empty/absent name never clears a populated one, a verified
///   assistant kind is never downgraded to generic `agent`, and the avatar is
///   tri-state (only `set`/`explicitClear` change a slot; `silent` leaves it).
/// - Metadata: a non-nil incoming map is the sender's authoritative whole map -
///   a winning event replaces the stored one. An empty map clears only the
///   conversation-scoped keys (`ConversationScopedMetadataKey`) so a revoked
///   grant propagates while a metadata-less name-only update cannot wipe
///   unrelated keys, and the cleared state persists as an empty-map tombstone
///   (distinct from nil/"never known") so a stale lower-source event cannot
///   fill revoked keys back in. Nil means the event says nothing about
///   metadata and the stored map is kept.
enum ProfileMerge {
    /// Trimmed, non-empty name, or nil. A name that is nil/blank/whitespace is
    /// treated as "no name provided".
    static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func isVerifiedAssistant(_ kind: DBMemberKind?) -> Bool {
        kind == .verifiedConvos || kind == .verifiedUserOAuth
    }

    /// Never downgrade a verified assistant to generic `agent` (or nil);
    /// otherwise prefer the incoming kind, falling back to the existing one.
    static func preserveVerifiedKind(_ existing: DBMemberKind?, _ incoming: DBMemberKind?) -> DBMemberKind? {
        if isVerifiedAssistant(existing), !isVerifiedAssistant(incoming) {
            return existing
        }
        return incoming ?? existing
    }

    static func mergeIdentity(
        existing: DBProfile?,
        inboxId: String,
        incoming: IncomingIdentity,
        source: ProfileSource,
        sentAt: Date
    ) -> DBProfile {
        guard let existing else {
            return DBProfile(
                inboxId: inboxId,
                name: nonBlank(incoming.name),
                memberKind: incoming.memberKind,
                metadata: nonEmpty(incoming.metadata),
                profileSource: source,
                updatedAt: sentAt
            )
        }

        var result = existing
        // Equal-time wins only for the local mirror tiers (see `winsOver`):
        // backfill and app-data stamp a constant floor, so their re-runs must
        // adopt changes; a wire event at an equal `sentAt` is a replay and
        // must be inert.
        let equalTimeWins = source == .contact || source == .appData
        if winsOver(existingSource: existing.profileSource, existingUpdatedAt: existing.updatedAt, source: source, sentAt: sentAt, equalTimeWins: equalTimeWins) {
            result.name = nonBlank(incoming.name) ?? existing.name
            result.memberKind = preserveVerifiedKind(existing.memberKind, incoming.memberKind)
            // A winning event's non-nil non-empty map replaces the stored one
            // wholesale; an empty map clears the conversation-scoped keys (a
            // revoked grant must not survive as stale metadata). Nil says
            // nothing and keeps the stored map.
            if let metadata = incoming.metadata {
                result.metadata = metadata.isEmpty ? clearingScopedKeys(existing.metadata) : metadata
            }
            result.profileSource = source
            result.updatedAt = sentAt
        } else {
            // Lower precedence or older: fill blanks only; keep provenance and
            // never let a low-priority event change an existing kind.
            result.name = existing.name ?? nonBlank(incoming.name)
            result.memberKind = existing.memberKind ?? incoming.memberKind
            result.metadata = existing.metadata ?? nonEmpty(incoming.metadata)
        }
        return result
    }

    /// Non-empty map, or nil. An empty map only means something (an explicit
    /// clear) to a winning event; blank-fill and fresh rows treat it as absent.
    private static func nonEmpty(_ metadata: ProfileMetadata?) -> ProfileMetadata? {
        metadata.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A winning event's empty map clears only the conversation-scoped keys.
    /// An omitted map decodes identically to an empty one, so a metadata-less
    /// update from a client that does not re-send its map must not wipe
    /// unrelated keys (e.g. the agent attestation) - and the scoped keys are
    /// the only ones whose senders always publish their current full state.
    /// The result may be an empty map: that is the tombstone that stops the
    /// fill-blank path from resurrecting revoked keys out of a stale snapshot;
    /// a nil (nothing was ever known) stays nil.
    private static func clearingScopedKeys(_ existing: ProfileMetadata?) -> ProfileMetadata? {
        guard var cleared = existing else { return nil }
        for key in ConversationScopedMetadataKey.all {
            cleared.removeValue(forKey: key)
        }
        return cleared
    }

    static func mergeAvatar(
        existing: DBProfileAvatar?,
        inboxId: String,
        conversationId: String,
        incoming: IncomingAvatar,
        source: ProfileSource,
        sentAt: Date
    ) -> DBProfileAvatar? {
        let setFields: AvatarFields?
        switch incoming {
        case .silent:
            return existing
        case .explicitClear:
            setFields = nil
        case let .set(url, salt, nonce, key):
            // Every profile avatar must be group-encrypted. A set missing any
            // crypto field is not a valid encrypted avatar; ignore it rather
            // than store an unencrypted slot or downgrade an existing encrypted
            // one to plaintext.
            guard let salt, let nonce, let key else {
                return existing
            }
            setFields = AvatarFields(url: url, salt: salt, nonce: nonce, key: key)
        }

        // Avatars require a strictly newer event to replace at the same source:
        // an equal `sentAt` is the same message re-applied (history catch-up
        // replays every launch), and replay must be inert - a `>=` here rebuilt
        // the slot each launch, wiping the asset-renewal stamp, and re-inserted
        // dead URLs that `ExpiredAssetRecoveryHandler` had deliberately
        // cleared. The cost is that a backfill-mirrored (`.contact`, floor)
        // avatar no longer tracks a changed legacy row; a real avatar change
        // always arrives as a ProfileUpdate, which wins at a higher source.
        let wins = existing.map {
            winsOver(existingSource: $0.profileSource, existingUpdatedAt: $0.updatedAt, source: source, sentAt: sentAt, equalTimeWins: false)
        } ?? true

        if wins {
            // A re-set of the same URL is not a new asset: carry the renewal
            // stamp and digest so recency churn can't mark a freshly renewed
            // URL as never-renewed and re-trigger the renewal sweep.
            let sameURL = setFields?.url == existing?.url
            return DBProfileAvatar(
                inboxId: inboxId,
                conversationId: conversationId,
                url: setFields?.url,
                salt: setFields?.salt,
                nonce: setFields?.nonce,
                encryptionKey: setFields?.key,
                profileSource: source,
                contentDigest: sameURL ? existing?.contentDigest : nil,
                updatedAt: sentAt,
                lastRenewed: sameURL ? existing?.lastRenewed : nil
            )
        }

        // Lower precedence or older: leave the slot untouched. Unlike a name
        // (where a nil value means "not yet known" and is gap-filled), an avatar
        // slot exists only because of a prior set or explicit clear, so a
        // url == nil slot is a tombstone, not an unknown - a lower/older event
        // must not resurrect it. A genuinely empty inbox has no slot at all
        // (existing == nil), which wins above and is created from any source.
        return existing
    }

    /// Precedence-and-recency: a higher source always wins; the same source
    /// wins on a strictly newer `sentAt`. What an equal `sentAt` means depends
    /// on the caller (`equalTimeWins`):
    ///
    /// - Identity merges let the local mirror tiers (`.contact` backfill,
    ///   `.appData`) win on equal time. Those writers stamp a constant floor,
    ///   so "equal" there means "the mirror re-ran" - and the mirror must adopt
    ///   legacy/app-data changes rather than freeze its first value.
    /// - Wire tiers and all avatar merges treat equal time as the same message
    ///   replayed, which must be inert (see `mergeAvatar`).
    private static func winsOver(
        existingSource: ProfileSource,
        existingUpdatedAt: Date,
        source: ProfileSource,
        sentAt: Date,
        equalTimeWins: Bool
    ) -> Bool {
        if source > existingSource { return true }
        guard source == existingSource else { return false }
        if sentAt > existingUpdatedAt { return true }
        return equalTimeWins && sentAt == existingUpdatedAt
    }

    /// The fields an avatar `set` carries, extracted so `mergeAvatar` avoids a
    /// four-member tuple.
    private struct AvatarFields {
        let url: String
        let salt: Data?
        let nonce: Data?
        let key: Data?
    }
}
