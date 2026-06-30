import Foundation

/// Pure merge rules for inbound identity and avatar updates. No I/O; the
/// repository calls these and persists the result. Combines two axes:
///
/// - Precedence: a higher `ProfileSource` always wins; within the same source,
///   the newer `sentAt` wins; a lower source only fills blanks.
/// - Guards: an empty/absent name never clears a populated one, a verified
///   assistant kind is never downgraded to generic `agent`, and the avatar is
///   tri-state (only `set`/`explicitClear` change a slot; `silent` leaves it).
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
                metadata: incoming.metadata,
                profileSource: source,
                updatedAt: sentAt
            )
        }

        var result = existing
        if winsOver(existingSource: existing.profileSource, existingUpdatedAt: existing.updatedAt, source: source, sentAt: sentAt) {
            result.name = nonBlank(incoming.name) ?? existing.name
            result.memberKind = preserveVerifiedKind(existing.memberKind, incoming.memberKind)
            result.metadata = incoming.metadata ?? existing.metadata
            result.profileSource = source
            result.updatedAt = sentAt
        } else {
            // Lower precedence or older: fill blanks only; keep provenance and
            // never let a low-priority event change an existing kind.
            result.name = existing.name ?? nonBlank(incoming.name)
            result.memberKind = existing.memberKind ?? incoming.memberKind
            result.metadata = existing.metadata ?? incoming.metadata
        }
        return result
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
            setFields = AvatarFields(url: url, salt: salt, nonce: nonce, key: key)
        }

        let wins = existing.map {
            winsOver(existingSource: $0.profileSource, existingUpdatedAt: $0.updatedAt, source: source, sentAt: sentAt)
        } ?? true

        if wins {
            return DBProfileAvatar(
                inboxId: inboxId,
                conversationId: conversationId,
                url: setFields?.url,
                salt: setFields?.salt,
                nonce: setFields?.nonce,
                encryptionKey: setFields?.key,
                profileSource: source,
                updatedAt: sentAt
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

    private static func winsOver(
        existingSource: ProfileSource,
        existingUpdatedAt: Date,
        source: ProfileSource,
        sentAt: Date
    ) -> Bool {
        source > existingSource || (source == existingSource && sentAt >= existingUpdatedAt)
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
