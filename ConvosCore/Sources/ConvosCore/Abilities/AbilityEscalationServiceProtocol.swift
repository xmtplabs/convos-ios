import Foundation

/// Client-side seam for agent-initiated ability-use requests and the
/// delegations they produce. Deliberately transport-free: the
/// authorization semantics (who may ask, how the ask travels, where
/// grants are stored) are still being decided server-side, so the only
/// implementation is the in-memory mock. When the real transport lands it
/// conforms here; every surface upstream of this protocol is already
/// final. Nothing in this contract implies a wire format.
///
/// Deliberately a sibling of `AbilitiesServiceProtocol`, not an extension
/// of it: extending would force `LiveAbilitiesService` to grow throwing
/// stubs for a flow that has no wire, and would smear the seam across two
/// files.
public protocol AbilityEscalationServiceProtocol: Sendable {
    /// Pending asks for one conversation, newest last.
    func pendingRequests(conversationId: String) async -> [AbilityDelegationRequest]

    /// Live view of the same: emits the full pending set on every change.
    /// The first emission is the current state.
    func pendingRequestsStream(conversationId: String) async -> AsyncStream<[AbilityDelegationRequest]>

    /// Every delegation ever granted for one ability, newest first,
    /// across conversations (the ability-detail list).
    func delegations(abilityId: String) async -> [AbilityDelegation]

    /// Resolves a pending request into a bounded delegation.
    /// Throws `requestAlreadyResolved` on a second resolution.
    @discardableResult
    func grant(requestId: String, bundleIds: [String], scope: AbilityDelegationScope) async throws -> AbilityDelegation

    /// Resolves a pending request negatively. No delegation is created.
    func decline(requestId: String) async throws

    /// Owner-initiated revocation of an active delegation.
    func revoke(delegationId: String) async throws
}
