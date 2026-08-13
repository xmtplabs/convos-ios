import Foundation

/// An agent's pending ask to use the owner's ability in a conversation.
public struct AbilityDelegationRequest: Sendable, Hashable, Identifiable {
    public let id: String
    public let conversationId: String
    public let agentInboxId: String
    /// Display name supplied by the serving layer; the mock seeds it
    /// directly, a future live path resolves it from members.
    public let agentDisplayName: String
    public let abilityId: String
    public let requestedBundleIds: [String]
    /// One human sentence of agent-supplied context ("Alex asked me to
    /// add the team dinner to your calendar").
    public let reason: String
    public let requestedAt: Date

    public init(
        id: String,
        conversationId: String,
        agentInboxId: String,
        agentDisplayName: String,
        abilityId: String,
        requestedBundleIds: [String],
        reason: String,
        requestedAt: Date
    ) {
        self.id = id
        self.conversationId = conversationId
        self.agentInboxId = agentInboxId
        self.agentDisplayName = agentDisplayName
        self.abilityId = abilityId
        self.requestedBundleIds = requestedBundleIds
        self.reason = reason
        self.requestedAt = requestedAt
    }
}

/// The bound the owner chose at grant time.
public enum AbilityDelegationScope: Sendable, Hashable {
    case oneShot
    case expiring(Date)
}

/// Stored lifecycle state of a granted delegation.
public enum AbilityDelegationState: String, Sendable, Hashable {
    case active
    /// One-shot, used.
    case consumed
    case expired
    case revoked
}

/// A bounded grant: this conversation, this agent, these bundles, this
/// scope. Requests that were declined never materialize as delegations.
public struct AbilityDelegation: Sendable, Hashable, Identifiable {
    public let id: String
    public let conversationId: String
    /// Display label for the delegations list; mock-seeded.
    public let conversationName: String
    public let agentInboxId: String
    public let agentDisplayName: String
    public let abilityId: String
    public let bundleIds: [String]
    public let scope: AbilityDelegationScope
    public let grantedAt: Date
    public let state: AbilityDelegationState

    public init(
        id: String,
        conversationId: String,
        conversationName: String,
        agentInboxId: String,
        agentDisplayName: String,
        abilityId: String,
        bundleIds: [String],
        scope: AbilityDelegationScope,
        grantedAt: Date,
        state: AbilityDelegationState
    ) {
        self.id = id
        self.conversationId = conversationId
        self.conversationName = conversationName
        self.agentInboxId = agentInboxId
        self.agentDisplayName = agentDisplayName
        self.abilityId = abilityId
        self.bundleIds = bundleIds
        self.scope = scope
        self.grantedAt = grantedAt
        self.state = state
    }

    /// Expiry is derived, never stored: an active expiring delegation
    /// whose instant has passed reads as expired everywhere.
    public func effectiveState(at now: Date = Date()) -> AbilityDelegationState {
        guard state == .active, case .expiring(let expiry) = scope, expiry <= now else {
            return state
        }
        return .expired
    }

    /// A copy of this delegation with `state` replaced, mirroring
    /// `AbilitiesAPI.Ability.withEntitlementState`.
    public func withState(_ state: AbilityDelegationState) -> AbilityDelegation {
        AbilityDelegation(
            id: id,
            conversationId: conversationId,
            conversationName: conversationName,
            agentInboxId: agentInboxId,
            agentDisplayName: agentDisplayName,
            abilityId: abilityId,
            bundleIds: bundleIds,
            scope: scope,
            grantedAt: grantedAt,
            state: state
        )
    }
}

/// Typed failures for the escalation seam, mirroring
/// `AbilitiesServiceError`'s style.
public enum AbilityEscalationServiceError: Error, Sendable, Equatable {
    case unknownRequest(requestId: String)
    case requestAlreadyResolved(requestId: String)
    case unknownDelegation(delegationId: String)
    case delegationNotActive(delegationId: String)
}

extension AbilityEscalationServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownRequest:
            "This request is no longer available."
        case .requestAlreadyResolved:
            "This request was already answered."
        case .unknownDelegation:
            "This delegation is no longer available."
        case .delegationNotActive:
            "This delegation is not active."
        }
    }
}
