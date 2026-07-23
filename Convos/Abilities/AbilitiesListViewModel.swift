import ConvosCore
import SwiftUI

@MainActor @Observable
final class AbilitiesListViewModel {
    private(set) var catalog: AbilitiesAPI.CatalogResponse?
    private(set) var isLoading: Bool = false
    private(set) var busyAbilityIds: Set<String> = []
    private(set) var errorMessage: String?
    var searchText: String = ""

    private let service: any AbilitiesServiceProtocol

    init(service: any AbilitiesServiceProtocol) {
        self.service = service
    }

    var entitlementsUnavailable: Bool {
        catalog?.entitlementsUnavailable ?? false
    }

    var hasLoadedOnce: Bool {
        catalog != nil
    }

    var isSearching: Bool {
        !trimmedQuery.isEmpty
    }

    /// Abilities the caller holds an entitlement for, in any lifecycle
    /// state. Under `entitlementsUnavailable` this reflects last-known
    /// state, already merged by the service.
    var entitledAbilities: [AbilitiesAPI.Ability] {
        filteredAbilities.filter { $0.entitlement != nil }
    }

    /// Catalog-only abilities the caller can connect.
    var availableAbilities: [AbilitiesAPI.Ability] {
        filteredAbilities.filter { $0.entitlement == nil }
    }

    func isBusy(_ ability: AbilitiesAPI.Ability) -> Bool {
        busyAbilityIds.contains(ability.id)
    }

    func refresh() async {
        if catalog == nil {
            isLoading = true
        }
        do {
            catalog = try await service.fetchCatalog()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Starts (or restarts, for expired and needs-reauth states) the
    /// entitlement. The transport returning `pendingAuth` hands its
    /// redirect URL to the OAuth session machinery; the mock service has
    /// no browser to bounce through, so completion follows immediately.
    func connect(_ ability: AbilitiesAPI.Ability) {
        guard !isBusy(ability) else { return }
        busyAbilityIds.insert(ability.id)
        errorMessage = nil
        Task {
            do {
                let initiation = try await service.beginEntitlement(abilityId: ability.id)
                if initiation.status == .pendingAuth {
                    try await service.completeEntitlement(abilityId: ability.id)
                }
                catalog = try await service.fetchCatalog()
            } catch {
                errorMessage = error.localizedDescription
            }
            busyAbilityIds.remove(ability.id)
        }
    }

    func disconnect(_ ability: AbilitiesAPI.Ability) {
        guard !isBusy(ability) else { return }
        busyAbilityIds.insert(ability.id)
        errorMessage = nil
        Task {
            do {
                try await service.revokeEntitlement(abilityId: ability.id)
                catalog = try await service.fetchCatalog()
            } catch {
                errorMessage = error.localizedDescription
            }
            busyAbilityIds.remove(ability.id)
        }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredAbilities: [AbilitiesAPI.Ability] {
        guard let catalog else { return [] }
        let sorted: [AbilitiesAPI.Ability] = catalog.abilities.sorted { lhs, rhs in
            lhs.displayName.resolved().localizedCaseInsensitiveCompare(rhs.displayName.resolved()) == .orderedAscending
        }
        let query = trimmedQuery
        guard !query.isEmpty else { return sorted }
        return sorted.filter { (ability: AbilitiesAPI.Ability) -> Bool in
            ability.displayName.resolved().localizedCaseInsensitiveContains(query)
                || ability.subtitle.resolved().localizedCaseInsensitiveContains(query)
        }
    }
}
