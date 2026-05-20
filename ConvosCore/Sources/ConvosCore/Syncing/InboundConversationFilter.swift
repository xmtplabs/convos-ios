import Foundation

/// Decision returned by `InboundConversationFilter` when an inbound
/// conversation arrives. The caller is responsible for the side effects:
/// `.deliver` persists normally; `.quarantine` persists with the
/// `quarantinedAt` flag set; `.reject` drops on the floor (matches today's
/// behavior for non-allowed conversations).
public enum InboundConversationDecision: Equatable, Sendable {
    case deliver
    case quarantine
    case reject
}

/// Pure decision function for the inbound-conversation gate. Extends today's
/// consent + invite-flow + creator-self check (`StreamProcessor.shouldProcessConversation`)
/// with two new branches: blocked-contact rejection and contact-list-driven
/// delivery / stranger quarantine.
///
/// The filter is intentionally side-effect-free. It does not mutate XMTP
/// consent state — `StreamProcessor` performs the `updateConsentState(.allowed)`
/// call when this filter returns `.deliver` for a previously-`.unknown`
/// conversation, preserving the existing behavior verbatim.
public struct InboundConversationFilter: Sendable {
    private let contactsRepository: any ContactsRepositoryProtocol

    public init(contactsRepository: any ContactsRepositoryProtocol) {
        self.contactsRepository = contactsRepository
    }

    /// Decides what to do with an inbound conversation given its context.
    ///
    /// - Parameters:
    ///   - consentState: XMTP-reported consent state at delivery time.
    ///   - creatorInboxId: `inboxId` of the sender / conversation creator.
    ///   - clientInboxId: the local user's `inboxId`.
    ///   - hasOutgoingJoinRequest: whether the local user has a pending
    ///     invite-flow join request for this conversation. Caller looks this
    ///     up via the existing `InviteJoinRequestsManager`.
    public func decide(
        consentState: Consent,
        creatorInboxId: String,
        clientInboxId: String,
        hasOutgoingJoinRequest: Bool
    ) -> InboundConversationDecision {
        // Already-accepted conversations bypass every other check. Blocking
        // does not retroactively quarantine an existing accepted convo;
        // see PRD, "Blocking" effects list. The user can still post in
        // groups they shared before the block; only new inbound from a
        // blocked sender is held.
        if consentState == .allowed { return .deliver }

        // Self-creator: the local user created this conversation.
        if creatorInboxId == clientInboxId { return .deliver }

        // Block path: quarantine instead of dropping. Held conversations
        // are persisted but hidden from the main feed; the
        // `QuarantineSweeper` promotes them on unblock or deletes them
        // past the TTL. This restores the conversation when the user
        // unblocks within the hold window.
        if (try? contactsRepository.isBlocked(inboxId: creatorInboxId)) == true {
            return .quarantine
        }

        if consentState == .unknown {
            // Existing invite-flow path. Caller bumps consent → .allowed
            // after delivery.
            if hasOutgoingJoinRequest { return .deliver }

            // New: known contact path. Caller bumps consent the same way.
            if (try? contactsRepository.isContact(inboxId: creatorInboxId)) == true {
                return .deliver
            }

            // Stranger — held in quarantine until the sender becomes a
            // contact (promoted) or the TTL expires (deleted).
            return .quarantine
        }

        // .denied or any future consent state we don't recognize — drop.
        return .reject
    }
}
