import Foundation

/// The catalog as consumed by view models: a wire response resolved
/// against last-known entitlement state per the availability contract.
/// Deliberately not a wire type -- under an outage it can carry both the
/// staleness marker and carried-forward entitlement states, a combination
/// the response schema forbids, so it is never re-encoded as a response.
public struct AbilitiesCatalog: Sendable, Hashable {
    public let catalogVersion: Int
    /// True when the serving response carried `entitlementsUnavailable`.
    /// Entitlement states below are then last-known -- or `.unknown` for
    /// abilities with no last-known state to carry forward, which the UI
    /// must present as "state unknown" with mutations withheld, never as
    /// "not connected".
    public let entitlementsUnavailable: Bool
    public let abilities: [AbilitiesAPI.Ability]

    public init(catalogVersion: Int, entitlementsUnavailable: Bool = false, abilities: [AbilitiesAPI.Ability]) {
        self.catalogVersion = catalogVersion
        self.entitlementsUnavailable = entitlementsUnavailable
        self.abilities = abilities
    }

    /// Resolves a wire response against the last-known catalog.
    /// Authoritative responses pass through unchanged -- an authoritative
    /// `null` is the truth and stale state never resurrects it. Under the
    /// flag, each ability's unknown state is replaced by the last-known
    /// state for that ability id when one exists; the result can be stored
    /// as the new last-known catalog so back-to-back outages keep carrying
    /// state forward.
    public static func resolving(response: AbilitiesAPI.CatalogResponse, lastKnown: AbilitiesCatalog?) -> AbilitiesCatalog {
        guard response.entitlementsUnavailable else {
            return AbilitiesCatalog(catalogVersion: response.catalogVersion, abilities: response.abilities)
        }
        let lastKnownAbilities: [AbilitiesAPI.Ability] = lastKnown?.abilities ?? []
        let lastKnownStates: [String: AbilitiesAPI.EntitlementState] = lastKnownAbilities
            .reduce(into: [:]) { (partial: inout [String: AbilitiesAPI.EntitlementState], ability: AbilitiesAPI.Ability) in
                if ability.entitlementState != .unknown {
                    partial[ability.id] = ability.entitlementState
                }
            }
        let merged: [AbilitiesAPI.Ability] = response.abilities.map { (ability: AbilitiesAPI.Ability) -> AbilitiesAPI.Ability in
            guard let state = lastKnownStates[ability.id] else { return ability }
            return ability.withEntitlementState(state)
        }
        return AbilitiesCatalog(catalogVersion: response.catalogVersion, entitlementsUnavailable: true, abilities: merged)
    }
}
