import ConvosCore
import SwiftUI

/// Context for the authorization step between `beginEntitlement` and
/// `completeEntitlement`: the redirect URL the user must approve. Track A
/// presents it in a stubbed sheet; the live transport hands the same URL
/// to the OAuth session machinery and calls the same completion path.
struct AbilityAuthorizationContext: Identifiable, Hashable {
    let ability: AbilitiesAPI.Ability
    let redirectUrl: String

    var id: String { ability.id }
}

@MainActor @Observable
final class AbilitiesListViewModel {
    private(set) var catalog: AbilitiesCatalog?
    private(set) var isLoading: Bool = false
    private(set) var busyAbilityIds: Set<String> = []
    private(set) var errorMessage: String?
    var searchText: String = ""
    /// Non-nil presents the authorization sheet for a pending entitlement.
    var pendingAuthorization: AbilityAuthorizationContext?

    /// Set when the sheet's approve action takes over the lifecycle, so
    /// the dismissal callback does not also run the cancel path.
    private var isCompletingAuthorization: Bool = false

    private let service: any AbilitiesServiceProtocol
    /// Browser-session authorizer for the live transport. Nil (mock mode)
    /// keeps the stub authorization sheet as the approval step.
    private let authorizer: (any AbilityAuthorizing)?

    init(service: any AbilitiesServiceProtocol, authorizer: (any AbilityAuthorizing)? = nil) {
        self.service = service
        self.authorizer = authorizer
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
    /// state, already resolved by the service.
    var entitledAbilities: [AbilitiesAPI.Ability] {
        filteredAbilities.filter { $0.entitlement != nil }
    }

    /// Abilities the caller is authoritatively not entitled to and can
    /// connect. Unknown states are deliberately excluded: an outage with
    /// no last-known state must never render as "Available".
    var availableAbilities: [AbilitiesAPI.Ability] {
        filteredAbilities.filter { $0.entitlementState == .notEntitled }
    }

    /// Abilities whose entitlement state could not be determined (outage
    /// with no last-known state). Rendered without connect controls.
    var unknownStateAbilities: [AbilitiesAPI.Ability] {
        filteredAbilities.filter { $0.entitlementState == .unknown }
    }

    var hasVisibleAbilities: Bool {
        !entitledAbilities.isEmpty || !availableAbilities.isEmpty || !unknownStateAbilities.isEmpty
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

    /// Starts (or restarts, for expired/needs-reauth/revoked states) the
    /// entitlement. A `pendingAuth` initiation with a redirect URL opens
    /// the authorization step: the injected browser authorizer when one is
    /// present (live transport), the stub sheet otherwise. Either way,
    /// completion only ever runs after the user approved it, mirroring the
    /// browser-callback boundary.
    func connect(_ ability: AbilitiesAPI.Ability) {
        guard !isBusy(ability) else { return }
        busyAbilityIds.insert(ability.id)
        errorMessage = nil
        Task {
            do {
                let initiation = try await service.beginEntitlement(abilityId: ability.id)
                catalog = try await service.fetchCatalog()
                if initiation.status == .pendingAuth, let redirectUrl = initiation.redirectUrl {
                    if let authorizer {
                        await runBrowserAuthorization(for: ability, redirectUrl: redirectUrl, using: authorizer)
                    } else {
                        pendingAuthorization = AbilityAuthorizationContext(ability: ability, redirectUrl: redirectUrl)
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            busyAbilityIds.remove(ability.id)
        }
    }

    /// Live-transport authorization: `ASWebAuthenticationSession` replaces
    /// the stub sheet, then the same complete/cancel lifecycle runs. On any
    /// failure the entitlement stays `pendingAuth` server-side, so a
    /// refresh leaves the row offering Continue and Disconnect; only
    /// non-cancel failures surface a message (`auth_incomplete` included,
    /// so the user knows to retry in a moment).
    private func runBrowserAuthorization(
        for ability: AbilitiesAPI.Ability,
        redirectUrl: String,
        using authorizer: any AbilityAuthorizing
    ) async {
        do {
            try await authorizer.authorize(redirectUrl: redirectUrl)
        } catch {
            await refresh()
            if !Self.isAuthorizationCancellation(error) {
                errorMessage = error.localizedDescription
            }
            return
        }
        do {
            try await service.completeEntitlement(abilityId: ability.id)
            catalog = try await service.fetchCatalog()
        } catch {
            await refresh()
            errorMessage = error.localizedDescription
        }
    }

    private static func isAuthorizationCancellation(_ error: Error) -> Bool {
        if case OAuthError.cancelled = error {
            return true
        }
        return false
    }

    /// The authorization step succeeded (in Track A, the stub sheet's
    /// approve; later, the OAuth callback): verify and activate.
    func completeAuthorization(_ context: AbilityAuthorizationContext) {
        isCompletingAuthorization = true
        pendingAuthorization = nil
        busyAbilityIds.insert(context.ability.id)
        Task {
            do {
                try await service.completeEntitlement(abilityId: context.ability.id)
                catalog = try await service.fetchCatalog()
            } catch {
                errorMessage = error.localizedDescription
            }
            busyAbilityIds.remove(context.ability.id)
        }
    }

    /// The Cancel button: dismisses the sheet. The actual cancel
    /// lifecycle runs in `handleAuthorizationDismissed`, the single funnel
    /// every dismissal path (button, swipe-down, programmatic) goes
    /// through.
    func cancelAuthorization() {
        pendingAuthorization = nil
    }

    /// Runs on every dismissal of the authorization sheet. Unless
    /// approval already took over, the entitlement stays `pendingAuth`
    /// server-side, so refresh: the row then offers Continue (re-runs
    /// `connect`, begin is idempotent) and Disconnect (revokes the pending
    /// entitlement) instead of a stale Connect.
    func handleAuthorizationDismissed() {
        guard !isCompletingAuthorization else {
            isCompletingAuthorization = false
            return
        }
        Task {
            await refresh()
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
        let sorted: [AbilitiesAPI.Ability] = catalog.abilities.sorted { (lhs: AbilitiesAPI.Ability, rhs: AbilitiesAPI.Ability) -> Bool in
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
