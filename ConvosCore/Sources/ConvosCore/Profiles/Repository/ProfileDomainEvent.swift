import Foundation

/// The identity fields carried by one inbound profile event, before merge.
struct IncomingIdentity: Hashable, Sendable {
    var name: String?
    var memberKind: DBMemberKind?
    var metadata: ProfileMetadata?

    init(name: String? = nil, memberKind: DBMemberKind? = nil, metadata: ProfileMetadata? = nil) {
        self.name = name
        self.memberKind = memberKind
        self.metadata = metadata
    }
}

/// How an inbound event addresses a member's avatar for a conversation. The
/// distinction is load-bearing for the merge: only `set` and `explicitClear`
/// change the slot; `silent` leaves it untouched (e.g. a name-only update).
enum IncomingAvatar: Hashable, Sendable {
    /// A new avatar for the slot. `salt`/`nonce`/`key` are present for encrypted
    /// avatars and nil for a plain URL.
    case set(url: String, salt: Data?, nonce: Data?, key: Data?)
    /// An explicit "avatar removed" intent (tombstone). Distinct from `silent`.
    case explicitClear
    /// The event does not address the avatar at all.
    case silent
}

/// A single inbound identity update for one `(inboxId, conversationId)`, tagged
/// with the source that produced it. `ProfilesRepository.apply` merges it into
/// the canonical stores by precedence and recency.
///
/// Constructed at the sync seam (see the inbound-seam PR) from decoded
/// `ProfileUpdate` / `ProfileSnapshot` / app-data; not used by the app yet.
struct ProfileDomainEvent: Sendable {
    let inboxId: String
    let conversationId: String
    let source: ProfileSource
    let identity: IncomingIdentity
    let avatar: IncomingAvatar
    let sentAt: Date
}
