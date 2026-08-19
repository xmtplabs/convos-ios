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
    /// Server-confirmed activations waiting for the authorization sheet to
    /// finish dismissing. `pendingAuthorization == nil` is not proof of
    /// dismissal -- `completeAuthorization` nils it before awaiting
    /// completion, and the real dismissal arrives separately through the
    /// sheet's `onDismiss`. Released exactly once, by
    /// `handleAuthorizationDismissed`.
    private var parkedActivations: [String] = []

    /// Fires once per ability whose entitlement just became active through
    /// this screen. `.composerModal` uses it to enable the ability for the
    /// launching chat; `.appSettings` leaves it nil.
    ///
    /// Carries the ability **id**, never an `Ability` value: none of the
    /// completion sites holds a refreshed one, and the pre-connect copy
    /// they do hold still reads not-entitled.
    var onEntitlementActivated: ((String) -> Void)?
    /// Fires with every catalog revision this view model commits, so a
    /// host owning a second view model can keep it on the same snapshot
    /// that sectioned the rows.
    var onCatalogCommitted: ((AbilitiesCatalog) -> Void)?

    private let service: any AbilitiesServiceProtocol
    /// Browser-session authorizer for the live transport. Nil (mock mode)
    /// keeps the stub authorization sheet as the approval step.
    private let authorizer: (any AbilityAuthorizing)?
    private let accountEpoch: AbilitiesAccountEpoch
    /// The account generation the published catalog belongs to. A wipe
    /// notifies no view model, so without this a screen open across one
    /// keeps rendering the previous account's connections.
    private var snapshotEpoch: UInt64

    init(
        service: any AbilitiesServiceProtocol,
        authorizer: (any AbilityAuthorizing)? = nil,
        accountEpoch: AbilitiesAccountEpoch = .shared
    ) {
        self.service = service
        self.authorizer = authorizer
        self.accountEpoch = accountEpoch
        self.snapshotEpoch = accountEpoch.value
    }

    var entitlementsUnavailable: Bool {
        currentCatalog?.entitlementsUnavailable ?? false
    }

    var hasLoadedOnce: Bool {
        currentCatalog != nil
    }

    /// The published catalog, or nil once the account generation behind it
    /// has been superseded. Reading the epoch here is what makes a wipe
    /// land on the next render rather than the next fetch.
    private var currentCatalog: AbilitiesCatalog? {
        guard snapshotEpoch == accountEpoch.value else { return nil }
        return catalog
    }

    var isSearching: Bool {
        !trimmedQuery.isEmpty
    }

    /// Whether the list should sell the feature rather than enumerate it:
    /// the catalog loaded authoritatively, the member is not searching, and
    /// they hold nothing. Withheld under `entitlementsUnavailable`, where
    /// every ability reads as not-entitled from last-known state and
    /// "nothing connected yet" would assert stale state as fact directly
    /// under a banner admitting the app cannot check.
    var showsNothingConnectedHero: Bool {
        hasLoadedOnce
            && !entitlementsUnavailable
            && !isSearching
            && entitledAbilities.isEmpty
            && !availableAbilities.isEmpty
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
        invalidateSnapshotIfEpochChanged()
        if catalog == nil {
            isLoading = true
        }
        let epoch: UInt64 = accountEpoch.value
        do {
            let fetched: AbilitiesCatalog = try await service.fetchCatalog()
            guard epoch == accountEpoch.value else { return }
            commitCatalog(fetched)
            errorMessage = nil
        } catch {
            guard epoch == accountEpoch.value else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// The one place `catalog` is published, so every host holding a
    /// second view model sees every revision this screen commits - not
    /// just the first.
    private func commitCatalog(_ fetched: AbilitiesCatalog) {
        catalog = fetched
        snapshotEpoch = accountEpoch.value
        onCatalogCommitted?(fetched)
    }

    /// Drops a catalog published under a superseded account generation, so
    /// a screen open across a wipe cannot keep rendering it.
    private func invalidateSnapshotIfEpochChanged() {
        let current: UInt64 = accountEpoch.value
        guard current != snapshotEpoch else { return }
        snapshotEpoch = current
        catalog = nil
        busyAbilityIds = []
        pendingAuthorization = nil
        parkedActivations = []
        errorMessage = nil
    }

    /// Starts (or restarts, for expired/needs-reauth/revoked states) the
    /// entitlement. A `pendingAuth` initiation with a redirect URL opens
    /// the authorization step: the injected browser authorizer when one is
    /// present (live transport), the stub sheet otherwise. Either way,
    /// completion only ever runs after the user approved it, mirroring the
    /// browser-callback boundary.
    func connect(_ ability: AbilitiesAPI.Ability) {
        guard !isBusy(ability), snapshotEpoch == accountEpoch.value else { return }
        busyAbilityIds.insert(ability.id)
        errorMessage = nil
        Task {
            do {
                let initiation = try await service.beginEntitlement(abilityId: ability.id)
                // Cosmetic mid-flow refresh (the row shows Continue and
                // Disconnect behind the authorization surface). It must
                // never gate the authorization step: begin has already
                // opened a backend OAuth round, and failing here would
                // strand it behind an error message.
                await refreshCatalogQuietly()
                if initiation.status == .pendingAuth, let redirectUrl = initiation.redirectUrl {
                    if let authorizer {
                        await runBrowserAuthorization(for: ability, redirectUrl: redirectUrl, using: authorizer)
                    } else {
                        pendingAuthorization = AbilityAuthorizationContext(ability: ability, redirectUrl: redirectUrl)
                    }
                } else {
                    // Auth-less abilities go active on begin alone, with no
                    // authorization step to complete: this branch is the only
                    // activation report they ever produce.
                    reportEntitlementActivated(abilityId: ability.id)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            busyAbilityIds.remove(ability.id)
        }
    }

    /// Mid-flow catalog refresh that must never derail the surrounding
    /// lifecycle: updates on success, quietly keeps the stale catalog
    /// otherwise (the flow's own completion refresh retries).
    private func refreshCatalogQuietly() async {
        guard let fetched = try? await service.fetchCatalog() else { return }
        guard snapshotEpoch == accountEpoch.value else { return }
        commitCatalog(fetched)
    }

    /// The single funnel every activation report goes through. Fires on
    /// the server-confirmed completion, never on the row having visibly
    /// moved: `refreshCatalogQuietly` is allowed to fail silently, and
    /// gating on the move would drop the report whenever it hiccups.
    ///
    /// While the stub authorization sheet is still dismissing the report
    /// is parked instead, so a follow-on sheet (the bundle picker) can
    /// never race that dismissal.
    private func reportEntitlementActivated(abilityId: String) {
        guard isCompletingAuthorization else {
            onEntitlementActivated?(abilityId)
            return
        }
        parkedActivations.append(abilityId)
    }

    private func releaseParkedActivations() {
        let released: [String] = parkedActivations
        parkedActivations = []
        for abilityId in released {
            onEntitlementActivated?(abilityId)
        }
    }

    /// Live-transport authorization: `ASWebAuthenticationSession` replaces
    /// the stub sheet, then the same complete/cancel lifecycle runs. On any
    /// failure the entitlement stays `pendingAuth` server-side, so a
    /// refresh leaves the row offering Continue and Disconnect; only
    /// non-cancel failures surface a message. Continue then resumes the
    /// same attempt: the service re-serves the retained consent URL and
    /// completion echoes the retained connection-request id -- it never
    /// mints a new backend connection request.
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
        // Completion and the follow-up refresh fail independently: after a
        // successful complete, the row update is quiet so a transient fetch
        // hiccup can never report the finished connect as failed; after a
        // failed complete, the mutation error wins over the refresh outcome.
        do {
            try await completeRetryingAuthIncomplete(abilityId: ability.id)
        } catch {
            await refresh()
            errorMessage = error.localizedDescription
            return
        }
        await refreshCatalogQuietly()
        reportEntitlementActivated(abilityId: ability.id)
    }

    /// Bounded same-attempt completion retry. `auth_incomplete` means the
    /// provider callback landed but the connection is not ACTIVE yet
    /// (still INITIALIZING); each retry re-submits the same retained
    /// connection-request id, which the service keeps across
    /// `auth_incomplete` failures. If it still isn't active after the
    /// budget, the final error surfaces its retry copy and the pending row
    /// offers Continue -- which resumes this same attempt.
    private func completeRetryingAuthIncomplete(abilityId: String) async throws {
        let retryDelays: [Duration] = [.seconds(1), .seconds(2)]
        for delay in retryDelays {
            do {
                try await service.completeEntitlement(abilityId: abilityId)
                return
            } catch AbilitiesAPI.EndpointError.authIncomplete {
                try await Task.sleep(for: delay)
            }
        }
        try await service.completeEntitlement(abilityId: abilityId)
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
                await refreshCatalogQuietly()
                reportEntitlementActivated(abilityId: context.ability.id)
            } catch {
                await refresh()
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
    ///
    /// This is also the second half of the activation latch: an activation
    /// confirmed while the sheet was still on screen is released here, so
    /// downstream work never presents a sheet into a dismissing one.
    func handleAuthorizationDismissed() {
        let wasCompleting: Bool = isCompletingAuthorization
        isCompletingAuthorization = false
        releaseParkedActivations()
        guard !wasCompleting else { return }
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
                await refreshCatalogQuietly()
            } catch {
                await refresh()
                errorMessage = error.localizedDescription
            }
            busyAbilityIds.remove(ability.id)
        }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredAbilities: [AbilitiesAPI.Ability] {
        guard let catalog = currentCatalog else { return [] }
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
