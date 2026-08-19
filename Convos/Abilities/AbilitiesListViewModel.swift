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

    /// Abilities the caller holds a usable account connection for: the
    /// OAuth round finished and left an entitlement the agent can act on,
    /// however that entitlement has aged since. Under
    /// `entitlementsUnavailable` this reflects last-known state, already
    /// resolved by the service.
    var entitledAbilities: [AbilitiesAPI.Ability] {
        filteredAbilities.filter { Self.section(for: $0) == .connected }
    }

    /// Abilities the caller can connect: no entitlement at all, or one
    /// still waiting on an authorization that never completed. Unknown
    /// states are deliberately excluded - an outage with no last-known
    /// state must never render as connectable.
    var availableAbilities: [AbilitiesAPI.Ability] {
        filteredAbilities.filter { Self.section(for: $0) == .discover }
    }

    /// Abilities whose entitlement state could not be determined (outage
    /// with no last-known state). Rendered without connect controls.
    var unknownStateAbilities: [AbilitiesAPI.Ability] {
        filteredAbilities.filter { Self.section(for: $0) == .statusUnknown }
    }

    /// Which of the browser's three sections an ability belongs in. Both
    /// modes share the mapping; only headers and row accessories differ.
    enum BrowserSection: Hashable {
        /// "Connected" in both modes.
        case connected
        /// "All connections" in app settings, "Discover" in the chat-scoped
        /// browser. Carries the Connect affordance in both.
        case discover
        /// "Status unknown": browsable, no controls.
        case statusUnknown
    }

    /// Section membership as one total function of entitlement state, so a
    /// status added to the wire contract has to be classified here rather
    /// than inheriting a default.
    ///
    /// `pendingAuth` is the entry that does not read the way its wire shape
    /// suggests. The backend writes it when authorization is *initiated*,
    /// not when it is being processed, so an OAuth the member abandoned at
    /// the provider's sign-in page leaves exactly the same record as one
    /// still on screen. Filing it under Connected therefore advertised
    /// accounts that were never linked, with a repair route that could only
    /// re-offer the dead consent link. It belongs in Discover, where
    /// Connect opens a fresh round - the only action that can actually
    /// finish the job.
    ///
    /// Everything else that is entitled stays Connected: `expired`,
    /// `needsReauth` and `revoked` all describe a connection that did exist
    /// and can be repaired in place, and the badge beside them is what
    /// tells the member what to fix.
    static func section(for ability: AbilitiesAPI.Ability) -> BrowserSection {
        switch ability.entitlementState {
        case .notEntitled:
            return .discover
        case .unknown:
            return .statusUnknown
        case .entitled(let entitlement):
            switch entitlement.status {
            case .pendingAuth:
                return .discover
            case .active, .expired, .needsReauth, .revoked:
                return .connected
            }
        }
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
            guard epoch == accountEpoch.value, epoch == snapshotEpoch else { return }
            commitCatalog(fetched)
            errorMessage = nil
        } catch {
            guard epoch == accountEpoch.value, epoch == snapshotEpoch else { return }
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

    /// Starts the entitlement, or restarts it for every state that can
    /// reach this method with one already on file (`pendingAuth` from a
    /// Discover row, `expired` / `needsReauth` / `revoked` from a Connected
    /// row's Reconnect).
    ///
    /// A restart never re-serves the previous consent URL -- that link
    /// session has its own expiry, and re-opening it is what walks the
    /// member into "this link has expired". The service does try to finish
    /// the outstanding round first, silently, which is why a connect tap on
    /// a row whose authorization already went through upstream comes straight
    /// back as active with no sign-in at all.
    ///
    /// A `pendingAuth` initiation with a redirect URL opens the
    /// authorization step: the injected browser authorizer when one is
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
                // Cosmetic mid-flow refresh, behind the authorization
                // surface. It must never gate the authorization step: begin
                // has already opened a backend OAuth round, and failing here
                // would strand it behind an error message.
                await refreshCatalogQuietly()
                if initiation.status == .pendingAuth {
                    // A pending entitlement with no redirect URL is a
                    // malformed response, not an auth-less ability: the
                    // server just said authorization is outstanding, so
                    // reporting activation here would assert the opposite.
                    guard let redirectUrl = initiation.redirectUrl else {
                        errorMessage = LiveAbilitiesServiceError.missingConnectionRequest(abilityId: ability.id).localizedDescription
                        busyAbilityIds.remove(ability.id)
                        return
                    }
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
        // Captured before the await, not read after it: the question is
        // whether this result belongs to the account it is about to be
        // committed to, and a wipe followed by a fresh refresh can leave
        // `snapshotEpoch == accountEpoch.value` true again for a result
        // fetched under the previous account.
        let epoch: UInt64 = accountEpoch.value
        guard let fetched = try? await service.fetchCatalog() else { return }
        guard epoch == accountEpoch.value, epoch == snapshotEpoch else { return }
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
    /// refresh returns the row to Discover offering Connect; only non-cancel
    /// failures surface a message. That Connect first re-submits the round
    /// already outstanding -- which resolves it outright if the provider
    /// finished in the meantime -- and only otherwise opens a new one
    /// against a new link session.
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
    /// budget, the final error surfaces its retry copy and the row returns
    /// to Discover -- where Connect re-submits this same id before minting
    /// anything, so a connection that finished INITIALIZING in the meantime
    /// lands with no second sign-in. Nothing else would ever complete it:
    /// the provider sends no webhook.
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
    /// server-side, so refresh: the row settles back into Discover with a
    /// live Connect (begin is idempotent) rather than sitting under
    /// Connected claiming an account the member never finished linking.
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
