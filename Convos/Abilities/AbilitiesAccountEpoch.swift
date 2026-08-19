import Foundation
import Observation

/// Monotonic generation of the account (and scope) the abilities surfaces
/// are rendering. `AbilitiesServices.handleAccountDataWiped` clears the
/// disk cache and the service actor but notifies no view model, and both
/// abilities view models retain their last snapshot when a refresh fails -
/// so a screen open across a wipe would otherwise keep rendering the
/// previous account's connections and accept a toggle against them.
///
/// View models capture the value before every await, refuse to publish a
/// result captured under an earlier one, and drop what they already
/// published the moment it moves. Reading `value` from a view-evaluated
/// computed property registers the observation, so the invalidation lands
/// on the next render rather than waiting for another fetch.
@MainActor
@Observable
final class AbilitiesAccountEpoch {
    static let shared: AbilitiesAccountEpoch = AbilitiesAccountEpoch()

    private(set) var value: UInt64 = 0

    func advance() {
        value &+= 1
    }
}
