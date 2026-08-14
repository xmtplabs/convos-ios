import ConvosCore
import Foundation
import Observation

/// Drives the ability detail screen: the delegations granted against one
/// ability across conversations, with owner-initiated revocation.
/// Pull-only: the list refreshes on appear and after its own mutations,
/// matching how `ConversationAbilitiesViewModel.refresh()` works.
@MainActor @Observable
final class AbilityDetailViewModel {
    let ability: AbilitiesAPI.Ability

    private(set) var delegations: [AbilityDelegation] = []
    private(set) var isLoading: Bool = false
    private(set) var errorMessage: String?
    private var isMutating: Bool = false

    private let selection: AbilitiesSelection

    init(ability: AbilitiesAPI.Ability, selection: AbilitiesSelection) {
        self.ability = ability
        self.selection = selection
    }

    /// Delegations whose derived state is active, newest first.
    var activeDelegations: [AbilityDelegation] {
        let now = Date()
        return delegations
            .filter { (delegation: AbilityDelegation) -> Bool in delegation.effectiveState(at: now) == .active }
            .sorted { (lhs: AbilityDelegation, rhs: AbilityDelegation) -> Bool in lhs.grantedAt > rhs.grantedAt }
    }

    /// Everything consumed, expired, or revoked, newest first.
    var pastDelegations: [AbilityDelegation] {
        let now = Date()
        return delegations
            .filter { (delegation: AbilityDelegation) -> Bool in delegation.effectiveState(at: now) != .active }
            .sorted { (lhs: AbilityDelegation, rhs: AbilityDelegation) -> Bool in lhs.grantedAt > rhs.grantedAt }
    }

    func refresh() async {
        isLoading = true
        delegations = await selection.escalation.delegations(abilityId: ability.id)
        isLoading = false
    }

    /// Mutate-then-refresh, copying `ConversationAbilitiesViewModel`'s
    /// withdraw shape: the service is the source of truth for the row's
    /// new state.
    func revoke(_ delegation: AbilityDelegation) {
        guard !isMutating else { return }
        isMutating = true
        errorMessage = nil
        Task {
            do {
                try await selection.escalation.revoke(delegationId: delegation.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            isMutating = false
            await refresh()
        }
    }

    /// Resolves bundle ids against the ability's bundle metadata, falling
    /// back to the raw id for anything the manifest no longer lists.
    func bundlesSummary(for delegation: AbilityDelegation) -> String {
        let titlesById: [String: String] = ability.bundles.reduce(into: [:]) { partial, bundle in
            partial[bundle.id] = bundle.title.resolved()
        }
        let titles: [String] = delegation.bundleIds.map { (bundleId: String) -> String in
            titlesById[bundleId] ?? bundleId
        }
        return titles.joined(separator: ", ")
    }
}
