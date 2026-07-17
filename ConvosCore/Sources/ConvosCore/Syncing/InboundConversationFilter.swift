import Foundation

/// Decision returned by `InboundConversationFilter` when an inbound
/// conversation arrives. `.deliver` persists normally; `.reject` drops
/// on the floor.
///
/// Persistence is orthogonal to feed visibility: we store inbound
/// conversations unless XMTP reports `.denied`. Visibility is keyed on
/// the stored consent state - `StreamProcessor` leaves an unsolicited
/// stranger at `.unknown` (hidden) and only bumps consent to `.allowed`
/// once the local user has consented (joined, or the creator is already
/// a contact). `ConversationConsentReconciler` promotes / demotes later
/// as contact state changes, and stale-stranger TTL cleanup runs as a
/// small periodic GC.
public enum InboundConversationDecision: Equatable, Sendable {
    case deliver
    case reject
}

/// Pure decision function for the inbound-conversation gate. Persistence
/// happens for everything except `.denied`; visibility is keyed on the
/// stored consent state downstream.
///
/// The filter is intentionally side-effect-free. `StreamProcessor` owns
/// the `updateConsentState(.allowed)` bump (gated on the local user
/// having consented - joined, or the creator already being a contact).
public struct InboundConversationFilter: Sendable {
    public init() {}

    /// Decides whether to persist an inbound conversation. `creatorInboxId`,
    /// `clientInboxId`, and `hasOutgoingJoinRequest` are accepted so the
    /// call site can keep them to hand for the consent-bump decision that
    /// `StreamProcessor` makes after this returns `.deliver`.
    public func decide(
        consentState: Consent,
        creatorInboxId _: String = "",
        clientInboxId _: String = "",
        hasOutgoingJoinRequest _: Bool = false
    ) -> InboundConversationDecision {
        // .denied -> drop. Everything else persists; consent state keyed
        // downstream decides whether it shows in the feed.
        switch consentState {
        case .allowed, .unknown:
            return .deliver
        case .denied:
            return .reject
        }
    }
}
