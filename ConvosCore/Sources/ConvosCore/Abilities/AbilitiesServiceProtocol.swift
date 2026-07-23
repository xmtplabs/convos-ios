import Foundation

/// Result of creating or restarting an entitlement for an ability.
/// OAuth abilities come back `pendingAuth` with a redirect URL to complete
/// in a browser session; auth-less abilities come back `active` immediately.
public struct AbilityEntitlementInitiation: Sendable, Hashable {
    public let status: AbilitiesAPI.EntitlementStatus
    public let redirectUrl: String?

    public init(status: AbilitiesAPI.EntitlementStatus, redirectUrl: String? = nil) {
        self.status = status
        self.redirectUrl = redirectUrl
    }
}

/// One (ability, agent) opt-in within a conversation: the caller's
/// entitlement extended to a specific agent, scoped by the agent's
/// immutable inbox id. Domain shape for the conversation info surface;
/// the serving endpoint (`GET /v2/conversations/{conversationId}/abilities`)
/// is not live yet, so this stays a client-side type until that wire
/// contract is frozen.
public struct ConversationAbility: Sendable, Hashable, Identifiable {
    public let abilityId: String
    public let agentInboxId: String
    public let bundleIds: [String]

    public var id: String { "\(abilityId)|\(agentInboxId)" }

    public init(abilityId: String, agentInboxId: String, bundleIds: [String]) {
        self.abilityId = abilityId
        self.agentInboxId = agentInboxId
        self.bundleIds = bundleIds
    }
}

/// Typed failures for ability mutations, mirroring the backend's error
/// vocabulary.
public enum AbilitiesServiceError: Error, Sendable, Equatable {
    /// A conversation extension was requested without an active
    /// entitlement (HTTP 409 `needs_entitlement`). The UI deep-links to
    /// the ability list so the user can connect first.
    case needsEntitlement(abilityId: String)
    /// The ability id is not in the served catalog.
    case unknownAbility(abilityId: String)
}

/// Backend-owned abilities: catalog enumeration, account-level entitlement
/// lifecycle, and extension of entitlements to agents within conversations.
/// The backend is the only source of truth; clients read statuses, never
/// derive them. `MockAbilitiesService` drives every V2 surface until the
/// live transport lands.
public protocol AbilitiesServiceProtocol: Sendable {
    /// Fetches the full catalog crossed with the caller's entitlement
    /// state. Implementations apply the availability contract: a response
    /// carrying `entitlementsUnavailable` keeps last-known entitlement
    /// state instead of downgrading abilities to "not connected".
    func fetchCatalog() async throws -> AbilitiesAPI.CatalogResponse

    /// Creates or restarts the caller's entitlement for `abilityId`.
    /// Idempotent per (account, ability).
    func beginEntitlement(abilityId: String) async throws -> AbilityEntitlementInitiation

    /// Completes a pending OAuth entitlement after the browser callback
    /// (post-callback ownership verification); flips it to `active`.
    func completeEntitlement(abilityId: String) async throws

    /// Revokes the entitlement; conversation extensions cascade.
    func revokeEntitlement(abilityId: String) async throws

    /// The conversation's opt-ins: one entry per (ability, agent).
    func conversationAbilities(conversationId: String) async throws -> [ConversationAbility]

    /// Extends (or updates) the caller's entitlement to `agentInboxId` in
    /// `conversationId` with the selected bundles. Requires an active
    /// entitlement; throws `AbilitiesServiceError.needsEntitlement`
    /// otherwise.
    func extendAbility(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async throws

    /// Withdraws that agent's opt-in for the ability.
    func withdrawAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws
}
