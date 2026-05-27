import Foundation

/// Decision returned by `InboundConversationFilter` when an inbound
/// conversation arrives. `.deliver` persists normally; `.reject` drops
/// on the floor.
///
/// Visibility used to be a third decision here (`.quarantine`), but the
/// "hide from feed until sender becomes a contact" rule moved to
/// `DBConversation.visibleInFeedPredicate` — a live join the
/// `ConversationsRepository` runs at read time. Persistence is now
/// orthogonal to visibility: we always store inbound conversations
/// unless XMTP itself reports `.denied`. The repository decides
/// whether to show them based on the current `contact` table, and
/// stale-stranger TTL cleanup runs as a small periodic GC.
public enum InboundConversationDecision: Equatable, Sendable {
    case deliver
    case reject
}

/// Pure decision function for the inbound-conversation gate. Persistence
/// happens for everything except `.denied`; visibility is derived
/// downstream.
///
/// The filter is intentionally side-effect-free. `StreamProcessor`
/// performs the `updateConsentState(.allowed)` call when this filter
/// returns `.deliver` for a previously-`.unknown` conversation,
/// preserving the existing behavior verbatim.
public struct InboundConversationFilter: Sendable {
    public init() {}

    /// Decides whether to persist an inbound conversation. `creatorInboxId`,
    /// `clientInboxId`, and `hasOutgoingJoinRequest` are accepted to keep
    /// the call-site signature stable while we migrate; the old
    /// per-relationship branching now lives in
    /// `DBConversation.visibleInFeedPredicate` (read-side join).
    public func decide(
        consentState: Consent,
        creatorInboxId _: String = "",
        clientInboxId _: String = "",
        hasOutgoingJoinRequest _: Bool = false
    ) -> InboundConversationDecision {
        // .denied → drop. Every other case persists; the feed-visibility
        // join hides rows whose creator isn't a (non-blocked) contact.
        switch consentState {
        case .allowed, .unknown:
            return .deliver
        case .denied:
            return .reject
        }
    }
}
