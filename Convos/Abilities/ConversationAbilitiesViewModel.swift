import ConvosCore
import SwiftUI

/// One agent in the conversation, snapshotted at view-model construction
/// the way the V1 connections section snapshots agent inbox ids. Extensions
/// bind to the agent's immutable inbox id; the display name only labels the
/// toggle in multi-agent conversations.
struct ConversationAgentDescriptor: Identifiable, Hashable {
    let inboxId: String
    let displayName: String

    var id: String { inboxId }
}

/// Where the catalog behind the rows comes from.
///
/// The conversation info view owns no catalog, so it fetches its own. The
/// Connections browser already fetched one to place each row in its
/// section, and a second fetch off the same actor at a different moment
/// can disagree with it - a row sitting in Connected while this view model
/// derives `.needsEntitlement` for it, and a dead toggle on a live
/// connection. Hosted mode therefore suppresses every self-fetch and takes
/// the host's snapshot instead.
enum ConversationAbilitiesCatalogSource {
    case selfFetching
    case hosted
}

/// Where a row without a usable entitlement sends the member to repair it.
///
/// The conversation info view presents its own scoped connect sheet. The
/// browser already has a connect flow on screen with its own sheet, so
/// arming a second one there would stack two connect surfaces on one
/// screen; it forwards the repair to the flow already present instead.
enum EntitlementRecoveryRoute {
    case inlineSheet
    case host((AbilitiesAPI.Ability) -> Void)
}

/// The three states of the per-conversation opt-in read, which is an
/// uncached network call with a different staleness profile from the
/// catalog. The third state is why this is not a `Bool`: reading a failed
/// or not-yet-landed fetch as "not enabled here" would render a settled
/// OFF over a selection the member already made, and the next tap would
/// extend with manifest defaults on top of it.
enum ConversationAbilityOptIns {
    case loading
    case authoritative([ConversationAbility])
    case unavailable

    /// The last authoritative set, which survives a failed refresh and is
    /// replaced only by a successful one.
    var authoritativeValues: [ConversationAbility]? {
        guard case .authoritative(let values) = self else { return nil }
        return values
    }

    var isSettled: Bool {
        authoritativeValues != nil
    }
}

/// Sheet context for choosing bundles before extending an ability to an
/// agent (only used when the ability has more than one bundle).
struct AbilityBundleSelectionContext: Identifiable, Hashable {
    let ability: AbilitiesAPI.Ability
    let agent: ConversationAgentDescriptor

    var id: ConversationAbilityKey {
        ConversationAbilityKey(abilityId: ability.id, agentInboxId: agent.inboxId)
    }
}

/// Sheet context for connecting an ability inline from the conversation
/// abilities section: the tapped ability, the agent whose row started the
/// flow, and how to continue once the connect succeeds. Mirrors
/// `AbilityBundleSelectionContext`'s shape for the sibling sheet.
struct ConversationAbilityConnectContext: Identifiable, Hashable {
    let ability: AbilitiesAPI.Ability
    let agent: ConversationAgentDescriptor
    /// True when a successful connect flows straight into extending the
    /// ability to the agent (the toggle-on path). False when an opt-in
    /// already exists and only the entitlement needed repair -- the opt-in
    /// and its bundle selection already stand and must not be overwritten.
    let continuesToExtension: Bool
    /// Bundles already chosen before a connect interrupted an extension
    /// (the extend call bounced with `needsEntitlement`); nil derives the
    /// selection after connect instead (bundle picker for multi-bundle
    /// abilities, manifest defaults otherwise).
    let preselectedBundleIds: [String]?

    var id: ConversationAbilityKey {
        ConversationAbilityKey(abilityId: ability.id, agentInboxId: agent.inboxId)
    }
}

@MainActor @Observable
final class ConversationAbilitiesViewModel {
    /// One toggle: an ability crossed with one agent. Single-agent
    /// conversations produce exactly one row per ability.
    struct Row: Identifiable, Hashable {
        /// How the row may be interacted with, derived from both the
        /// opt-in and the backing entitlement's lifecycle status -- an
        /// opt-in whose entitlement is not active is never presented as
        /// usable.
        enum Lifecycle: Hashable {
            /// Active entitlement: the toggle works normally.
            case ready
            /// An opt-in exists but the backing entitlement is not
            /// active (expired, pending, needs reauth, revoked, or gone):
            /// shown with a lifecycle warning that deep-links to the
            /// abilities list to resolve it.
            case needsAttention(AbilitiesAPI.EntitlementStatus?)
            /// No opt-in and no active entitlement: toggling on
            /// deep-links to the abilities list to connect first.
            case needsEntitlement
            /// Entitlement state unknown (outage with no last-known
            /// state): read-only until an authoritative response.
            case unknown
        }

        let ability: AbilitiesAPI.Ability
        let agent: ConversationAgentDescriptor
        let isOn: Bool
        let lifecycle: Lifecycle
        /// False while the opt-in read has produced no authoritative
        /// answer for this conversation yet: the control renders disabled
        /// rather than a settled OFF.
        let hasSettledOptIn: Bool
        /// True while an auto-enable started by a connect has not reached
        /// a terminal state: the control reads on and busy, so the member
        /// never sees the thing they just connected land as OFF.
        let isPendingEnablement: Bool

        var id: ConversationAbilityKey {
            ConversationAbilityKey(abilityId: ability.id, agentInboxId: agent.inboxId)
        }
    }

    private var builtRows: [Row] = []
    private(set) var isBusy: Bool = false
    private(set) var errorMessage: String?
    /// Non-nil presents the bundle picker sheet.
    var bundleSelection: AbilityBundleSelectionContext?
    /// Non-nil presents the inline connect sheet: the tapped ability has no
    /// active entitlement, so the user connects (or reconnects) it right
    /// here instead of detouring through App Settings. Never assigned under
    /// a `.host` recovery route.
    var connectContext: ConversationAbilityConnectContext?
    /// Parked continuation for a connect that succeeded: the connect sheet
    /// finishes dismissing first, then `handleConnectSheetDismissed` flows
    /// into the extension, so the bundle picker never races the dismissal.
    private var pendingExtensionAfterConnect: ConversationAbilityConnectContext?

    private var catalog: AbilitiesCatalog?
    private var optIns: ConversationAbilityOptIns = .loading
    /// Keys whose enablement was started by a connect and has not settled.
    /// Every exit is named in `clearPendingEnablement` callers; a key left
    /// here would hang its row on a spinner forever.
    private var pendingEnablement: Set<ConversationAbilityKey> = []
    /// The key of the bundle picker currently on screen, so its dismissal
    /// can clear the right pending enablement (`sheet(item:onDismiss:)`
    /// hands the closure nothing).
    private var presentedBundleSelectionKey: ConversationAbilityKey?
    /// Set by the picker's confirm so the dismissal that follows is not
    /// read as a cancellation -- `onDismiss` fires for both.
    private var isConfirmingBundleSelection: Bool = false

    /// The refresh chain, so every refresh runs after the one before it
    /// (see `refresh(adoptingCatalog:)`).
    private var refreshTask: Task<Void, Never>?
    /// The mutation in flight, so an auto-enable can wait for it instead
    /// of being dropped on `extend`'s busy guard.
    private var mutationTask: Task<Void, Never>?
    /// Monotonic refresh stamp: a result whose stamp is not the latest is
    /// dropped. Belt-and-braces behind the serialization above, and the
    /// gate that also refuses a commit from a superseded account.
    private var refreshGeneration: UInt64 = 0
    /// The account generation the published snapshot belongs to.
    private var snapshotEpoch: UInt64

    private let conversationId: String
    private let agents: [ConversationAgentDescriptor]
    /// The (service, authorizer) pair latched at construction; both halves
    /// travel together so the needs-entitlement sheet can never mix modes.
    private let selection: AbilitiesSelection
    private let catalogSource: ConversationAbilitiesCatalogSource
    private let accountEpoch: AbilitiesAccountEpoch

    /// Where a row without a usable entitlement routes its repair. Set by
    /// the host after construction when the host owns the connect flow.
    var entitlementRecoveryRoute: EntitlementRecoveryRoute = .inlineSheet
    /// Fires once every extend or withdraw has settled and the opt-ins have
    /// been re-read. The Connections browser hosting these toggles counts
    /// convos from its own read, which this mutation just invalidated.
    var onOptInsMutated: (() -> Void)?

    private var service: any AbilitiesServiceProtocol { selection.service }

    init(
        conversationId: String,
        agents: [ConversationAgentDescriptor],
        selection: AbilitiesSelection,
        catalogSource: ConversationAbilitiesCatalogSource = .selfFetching,
        accountEpoch: AbilitiesAccountEpoch = .shared
    ) {
        self.conversationId = conversationId
        self.agents = agents
        self.selection = selection
        self.catalogSource = catalogSource
        self.accountEpoch = accountEpoch
        self.snapshotEpoch = accountEpoch.value
        // A hosted view model never fetches a catalog of its own; the host
        // publishes the one that sectioned the rows.
        if catalogSource == .selfFetching {
            refreshSoon()
        }
    }

    /// Empty while the published snapshot belongs to a superseded account:
    /// reading the epoch here is what makes the invalidation land on the
    /// next render instead of the next fetch.
    var rows: [Row] {
        guard snapshotEpoch == accountEpoch.value else { return [] }
        return builtRows
    }

    var isSingleAgent: Bool {
        agents.count == 1
    }

    /// True when the catalog behind these rows was served without
    /// authoritative entitlement state.
    var entitlementsUnavailable: Bool {
        catalog?.entitlementsUnavailable ?? false
    }

    /// Whether an outage withholds the per-chat control.
    ///
    /// Only where the browser sections rows by carried-forward state: there
    /// a row can sit under Connected on an entitlement revoked elsewhere
    /// since, and writing a grant against one the app admits it cannot
    /// verify is the mutation the outage machinery exists to stop. The
    /// conversation info view sections nothing and keeps its shipped
    /// behavior, which this addendum does not change.
    private var outageWithholdsToggle: Bool {
        catalogSource == .hosted && entitlementsUnavailable
    }

    /// The one disabled rule behind every per-chat control, on both
    /// surfaces. It closes on any state where a tap could write a grant
    /// the app cannot stand behind:
    /// - a mutation already in flight, so no toggle is left tappable for
    ///   `toggle` to silently drop on its `isBusy` guard;
    /// - an entitlement state the backend could not report;
    /// - an opt-in read that has not settled, which must never render as
    ///   a settled OFF over a selection the member already made;
    /// - an auto-enable still landing;
    /// - a browser row sectioned from a catalog served without
    ///   authoritative entitlement state.
    func isToggleDisabled(for row: Row) -> Bool {
        if isBusy || outageWithholdsToggle { return true }
        if row.lifecycle == .unknown { return true }
        return !row.hasSettledOptIn || row.isPendingEnablement
    }

    /// The row for one ability, for hosts that render their own sections
    /// and cross them with these toggles. Nil means this view model has
    /// not caught up with the host's catalog yet - which the host renders
    /// as loading, never as off.
    func row(forAbilityId abilityId: String) -> Row? {
        rows.first { $0.ability.id == abilityId }
    }

    func refreshSoon() {
        Task { await refresh() }
    }

    func refresh() async {
        await refresh(adoptingCatalog: nil)
    }

    /// Refreshes opt-ins against a catalog the host already owns, instead
    /// of fetching a second copy that can disagree with the one that
    /// placed the row in its section. `nil` keeps the self-fetching
    /// behavior of the conversation info view, which owns no catalog.
    ///
    /// Both halves still commit together: publishing a fresh catalog with
    /// stale or empty opt-ins would render opted-in rows as off, and
    /// toggling one on would then overwrite the agent's real bundle
    /// selection with defaults. An adopted catalog is published up front
    /// against the *retained* authoritative opt-ins, which is the same
    /// guarantee - rows with no authoritative opt-in yet render unsettled.
    ///
    /// Refreshes run one at a time and in order. The service actor's
    /// sequence guard protects its own cache commit, not each caller's
    /// returned value, so overlapping refreshes could otherwise let an
    /// older opt-in response land after a newer one - and a caller's
    /// `await` would not reflect the state the screen ends up with.
    func refresh(adoptingCatalog adopted: AbilitiesCatalog?) async {
        if let adopted {
            applyAdoptedCatalog(adopted)
        }
        await refreshOptIns(selfFetchesCatalog: adopted == nil)
    }

    /// Publishes the host's catalog on the spot, before any queued work.
    /// Deferring this behind an in-flight opt-in refresh would leave the
    /// rows sectioned by a catalog this view model has not adopted yet -
    /// long enough for a toggle to stay enabled against an outage the
    /// screen has already declared.
    private func applyAdoptedCatalog(_ adopted: AbilitiesCatalog) {
        invalidateSnapshotIfEpochChanged()
        catalog = adopted
        rebuildRows()
    }

    /// The opt-in half, which is the only part that queues. Runs one at a
    /// time and in order: the service actor's sequence guard protects its
    /// own cache commit, not each caller's returned value, so overlapping
    /// refreshes could otherwise let an older response land after a newer
    /// one - and a caller's `await` would not reflect the state the
    /// screen ends up with.
    private func refreshOptIns(selfFetchesCatalog: Bool) async {
        let previous: Task<Void, Never>? = refreshTask
        let task: Task<Void, Never> = Task { [weak self] in
            _ = await previous?.value
            await self?.performRefresh(selfFetchesCatalog: selfFetchesCatalog)
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh(selfFetchesCatalog: Bool) async {
        invalidateSnapshotIfEpochChanged()
        refreshGeneration &+= 1
        let generation: UInt64 = refreshGeneration
        let epoch: UInt64 = accountEpoch.value
        do {
            let fetchedCatalog: AbilitiesCatalog? = try await resolveCatalog(selfFetches: selfFetchesCatalog)
            let fetchedOptIns: [ConversationAbility] = try await service.conversationAbilities(conversationId: conversationId)
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            if let fetchedCatalog {
                catalog = fetchedCatalog
            }
            optIns = .authoritative(fetchedOptIns)
            errorMessage = nil
        } catch {
            guard isCurrent(generation: generation, epoch: epoch) else { return }
            // A failed read never demotes a set the member already saw; it
            // only names the never-loaded case, which renders disabled.
            if !optIns.isSettled {
                optIns = .unavailable
            }
            errorMessage = error.localizedDescription
        }
        rebuildRows()
    }

    /// The catalog half of a refresh. A hosted view model never fetches
    /// one - not from its initializer and not after a mutation: the host
    /// publishes the snapshot that sectioned the rows, and a second fetch
    /// off the same actor at another moment can disagree with it. `nil`
    /// leaves whatever the host last published in place.
    private func resolveCatalog(selfFetches: Bool) async throws -> AbilitiesCatalog? {
        guard selfFetches, catalogSource == .selfFetching else { return nil }
        return try await service.fetchCatalog()
    }

    /// Publishes a catalog revision the host committed. Called for every
    /// revision, not just the first: the browser refreshes from its
    /// `.task`, its pull-to-refresh, and its mid-connect quiet refreshes
    /// throughout the session.
    func adoptCatalog(_ adopted: AbilitiesCatalog) {
        guard catalogSource == .hosted else { return }
        applyAdoptedCatalog(adopted)
        Task { await refreshOptIns(selfFetchesCatalog: false) }
    }

    private func isCurrent(generation: UInt64, epoch: UInt64) -> Bool {
        generation == refreshGeneration && epoch == accountEpoch.value && epoch == snapshotEpoch
    }

    /// Drops everything published under an earlier account generation, so
    /// a wipe can neither survive in the rows nor be crossed with the next
    /// account's catalog.
    private func invalidateSnapshotIfEpochChanged() {
        let current: UInt64 = accountEpoch.value
        guard current != snapshotEpoch else { return }
        snapshotEpoch = current
        catalog = nil
        optIns = .loading
        pendingEnablement = []
        presentedBundleSelectionKey = nil
        bundleSelection = nil
        connectContext = nil
        pendingExtensionAfterConnect = nil
        errorMessage = nil
        builtRows = []
    }

    func toggle(_ row: Row) {
        guard !isBusy, snapshotEpoch == accountEpoch.value else { return }
        guard !outageWithholdsToggle else { return }
        switch row.lifecycle {
        case .ready:
            if row.isOn {
                withdraw(ability: row.ability, agent: row.agent)
            } else {
                requestExtension(for: row)
            }
        case .needsAttention, .needsEntitlement:
            presentConnect(for: row)
        case .unknown:
            break
        }
    }

    /// Routes a row without a usable entitlement to its repair flow. Rows
    /// not yet opted in continue into the extension after a successful
    /// connect; already-opted-in rows (needs-attention) only repair the
    /// entitlement, since their opt-in and bundle selection already stand.
    func presentConnect(for row: Row) {
        routeEntitlementRecovery(
            ability: row.ability,
            agent: row.agent,
            continuesToExtension: !row.isOn,
            preselectedBundleIds: nil
        )
    }

    /// The one place `connectContext` is assigned, so a host that owns its
    /// own connect flow can guarantee no second sheet is ever armed.
    private func routeEntitlementRecovery(
        ability: AbilitiesAPI.Ability,
        agent: ConversationAgentDescriptor,
        continuesToExtension: Bool,
        preselectedBundleIds: [String]?
    ) {
        switch entitlementRecoveryRoute {
        case .inlineSheet:
            connectContext = ConversationAbilityConnectContext(
                ability: ability,
                agent: agent,
                continuesToExtension: continuesToExtension,
                preselectedBundleIds: preselectedBundleIds
            )
        case .host(let route):
            route(ability)
        }
    }

    /// The connect sheet reports the entitlement went active. Park the
    /// continuation with the refreshed ability (the pre-connect copy still
    /// carries the stale entitlement) and dismiss the sheet;
    /// `handleConnectSheetDismissed` picks the continuation up.
    func handleConnected(_ refreshedAbility: AbilitiesAPI.Ability) {
        guard let context = connectContext else { return }
        if context.continuesToExtension {
            pendingExtensionAfterConnect = ConversationAbilityConnectContext(
                ability: refreshedAbility,
                agent: context.agent,
                continuesToExtension: true,
                preselectedBundleIds: context.preselectedBundleIds
            )
        }
        connectContext = nil
    }

    /// Runs on every dismissal of the connect sheet. A parked continuation
    /// means the connect succeeded: flow into the extension. Anything else
    /// (cancel, swipe-down, failure) just refreshes -- the toggle was never
    /// optimistically flipped, so it reads off again by construction.
    func handleConnectSheetDismissed() {
        if let pending = pendingExtensionAfterConnect {
            pendingExtensionAfterConnect = nil
            continueExtensionAfterConnect(pending)
        } else {
            refreshSoon()
        }
    }

    private func continueExtensionAfterConnect(_ context: ConversationAbilityConnectContext) {
        let ability = context.ability
        guard ability.entitlement?.status == .active else {
            refreshSoon()
            return
        }
        if let bundleIds = context.preselectedBundleIds {
            extend(ability: ability, agent: context.agent, bundleIds: bundleIds)
            return
        }
        guard !ability.bundles.isEmpty else {
            errorMessage = LiveAbilitiesServiceError.noBundlesSelected(abilityId: ability.id).localizedDescription
            refreshSoon()
            return
        }
        if ability.bundles.count > 1 {
            // Refresh beneath the picker so the rows already show the
            // now-active entitlement while the user chooses bundles.
            refreshSoon()
            presentBundleSelection(ability: ability, agent: context.agent)
        } else {
            extend(ability: ability, agent: context.agent, bundleIds: defaultBundleIds(for: ability))
        }
    }

    // MARK: - Auto-enable after a connect

    /// Enables the just-connected ability for this conversation. Keyed by
    /// id on purpose: activation is the caller's server-confirmed fact,
    /// and every connect completion site still holds the *pre-connect*
    /// ability, whose embedded entitlement reads not-entitled - handing
    /// that object to the extension path would bounce it straight back to
    /// Connect. The bundles are resolved from the freshest catalog
    /// instead. No-op when an opt-in already exists.
    func enableAfterConnect(abilityId: String) {
        guard snapshotEpoch == accountEpoch.value else { return }
        guard let agent = agents.first else { return }
        let key = ConversationAbilityKey(abilityId: abilityId, agentInboxId: agent.inboxId)
        guard !pendingEnablement.contains(key) else { return }
        // Only a settled read can say "no opt-in here". An unsettled one
        // is unknown, and `extendAfterConnect` settles it before writing.
        if optIns.isSettled, isOptedIn(key) { return }
        pendingEnablement.insert(key)
        errorMessage = nil
        rebuildRows()
        Task { await extendAfterConnect(abilityId: abilityId, agent: agent, key: key) }
    }

    private func extendAfterConnect(abilityId: String, agent: ConversationAgentDescriptor, key: ConversationAbilityKey) async {
        // Never extend over a selection that has not been read. The
        // three-state opt-in model is a write rule as much as a render
        // rule: treating a failed or in-flight read as "not opted in"
        // would PUT manifest defaults over the member's saved bundles.
        if !optIns.isSettled {
            await refreshOptIns(selfFetchesCatalog: false)
        }
        guard optIns.isSettled else {
            clearPendingEnablement(key)
            errorMessage = String(localized: "Couldn't check this convo's connections. Try again.")
            return
        }
        guard !isOptedIn(key) else {
            clearPendingEnablement(key)
            return
        }
        // An in-flight mutation must not swallow the enablement on
        // `extend`'s busy guard: wait for it instead of dropping it.
        _ = await mutationTask?.value
        guard let ability = await entitledAbility(id: abilityId) else {
            clearPendingEnablement(key)
            errorMessage = AbilitiesServiceError.needsEntitlement(abilityId: abilityId).localizedDescription
            return
        }
        guard !ability.bundles.isEmpty else {
            // The extension PUT requires a non-empty bundle selection, so
            // this can never reach `extend`: clear the pending row here or
            // it spins forever.
            clearPendingEnablement(key)
            errorMessage = LiveAbilitiesServiceError.noBundlesSelected(abilityId: abilityId).localizedDescription
            return
        }
        if ability.bundles.count > 1 {
            presentBundleSelection(ability: ability, agent: agent)
        } else {
            extend(ability: ability, agent: agent, bundleIds: defaultBundleIds(for: ability))
        }
    }

    /// The freshest active-entitlement copy of `abilityId`: the published
    /// catalog when it already carries one, else a targeted refetch. Never
    /// re-derives activation from a pre-connect object.
    private func entitledAbility(id abilityId: String) async -> AbilitiesAPI.Ability? {
        if let published = activeAbility(id: abilityId, in: catalog) {
            return published
        }
        // Captured before the await: the question is whether this result
        // belongs to the account it is about to be used under, not
        // whether some account is current by the time it returns.
        let epoch: UInt64 = accountEpoch.value
        guard let refetched = try? await service.fetchCatalog() else { return nil }
        guard epoch == accountEpoch.value, epoch == snapshotEpoch else { return nil }
        return activeAbility(id: abilityId, in: refetched)
    }

    private func activeAbility(id abilityId: String, in catalog: AbilitiesCatalog?) -> AbilitiesAPI.Ability? {
        guard let match = catalog?.abilities.first(where: { $0.id == abilityId }) else { return nil }
        return match.entitlement?.status == .active ? match : nil
    }

    /// Rebuilds on the spot: `Row` is a value type, so a confirmed write
    /// that only mutates the set would leave the rendered row on-and-busy
    /// until the trailing refetch returns - the exact spinner the
    /// settle-on-the-write rule exists to avoid.
    private func clearPendingEnablement(_ key: ConversationAbilityKey) {
        guard pendingEnablement.remove(key) != nil else { return }
        rebuildRows()
    }

    private func isOptedIn(_ key: ConversationAbilityKey) -> Bool {
        optIns.authoritativeValues?.contains { $0.key == key } ?? false
    }

    // MARK: - Bundle picker

    private func presentBundleSelection(ability: AbilitiesAPI.Ability, agent: ConversationAgentDescriptor) {
        let context = AbilityBundleSelectionContext(ability: ability, agent: agent)
        presentedBundleSelectionKey = context.id
        bundleSelection = context
    }

    /// The picker's confirm. Marks the dismissal that follows as a
    /// confirmation, so it is not read as the cancel exit.
    func confirmBundleSelection(_ context: AbilityBundleSelectionContext, bundleIds: [String]) {
        isConfirmingBundleSelection = true
        extend(ability: context.ability, agent: context.agent, bundleIds: bundleIds)
    }

    /// Runs on every dismissal of the picker. A cancel (or swipe-away)
    /// with an auto-enable behind it must settle the row off rather than
    /// leave it spinning.
    func handleBundleSelectionDismissed() {
        let key: ConversationAbilityKey? = presentedBundleSelectionKey
        presentedBundleSelectionKey = nil
        let wasConfirming: Bool = isConfirmingBundleSelection
        isConfirmingBundleSelection = false
        guard !wasConfirming, let key else { return }
        clearPendingEnablement(key)
    }

    // MARK: - Mutations

    /// Extends `ability` to `agent` with an explicit bundle selection
    /// (called by the bundle picker sheet's confirm).
    func extend(ability: AbilitiesAPI.Ability, agent: ConversationAgentDescriptor, bundleIds: [String]) {
        let key = ConversationAbilityKey(abilityId: ability.id, agentInboxId: agent.inboxId)
        guard snapshotEpoch == accountEpoch.value else {
            clearPendingEnablement(key)
            return
        }
        guard !isBusy else {
            // Auto-enable awaits `mutationTask` before reaching here, so
            // this is a last resort - but it must still say so rather
            // than settle the row off with no explanation.
            let wasPending: Bool = pendingEnablement.contains(key)
            clearPendingEnablement(key)
            if wasPending {
                errorMessage = String(localized: "Another change was still saving. Try turning this on again.")
            }
            return
        }
        isBusy = true
        errorMessage = nil
        let task = Task {
            var mutationError: String?
            do {
                try await service.extendAbility(
                    conversationId: conversationId,
                    abilityId: ability.id,
                    agentInboxId: agent.inboxId,
                    bundleIds: bundleIds
                )
                // Settle on the confirmed write, not on the refetch below:
                // the read can fail while the write succeeded, and gating
                // the visual settle on it would strand a real enablement
                // on a spinner.
                clearPendingEnablement(key)
                // The write above already ran under the epoch guard, so the
                // announcement needs no fence of its own. Best-effort inside
                // the announcer: a failed announcement never reverts the
                // toggle, the agent just cards once.
                await selection.announcer?.announceEnabled(
                    conversationId: conversationId,
                    agentInboxId: agent.inboxId,
                    abilityId: ability.id,
                    bundleIds: bundleIds
                )
            } catch AbilitiesServiceError.needsEntitlement {
                // The server says the entitlement is gone mid-extend: run
                // the repair flow and retry with the bundles the user
                // already chose, instead of re-opening the picker.
                clearPendingEnablement(key)
                routeEntitlementRecovery(
                    ability: ability,
                    agent: agent,
                    continuesToExtension: true,
                    preselectedBundleIds: bundleIds
                )
            } catch {
                clearPendingEnablement(key)
                mutationError = error.localizedDescription
            }
            isBusy = false
            await refresh()
            onOptInsMutated?()
            // The refresh clears errorMessage on success; re-assert the
            // mutation failure so the bounced-back toggle is explained.
            if let mutationError {
                errorMessage = mutationError
            }
        }
        mutationTask = task
    }

    /// The selection driving this conversation's rows. The connect sheet
    /// receives the whole pair, so a connect there mutates the same service
    /// these rows read and its authorizer always matches this service.
    var abilitiesSelection: AbilitiesSelection { selection }

    private func requestExtension(for row: Row) {
        let ability = row.ability
        guard ability.entitlement?.status == .active else {
            presentConnect(for: row)
            return
        }
        guard !ability.bundles.isEmpty else {
            // The extension PUT requires a non-empty bundle selection, so
            // a zero-bundle catalog ability cannot be extended yet: explain
            // immediately instead of bouncing through a doomed mutation.
            errorMessage = LiveAbilitiesServiceError.noBundlesSelected(abilityId: ability.id).localizedDescription
            return
        }
        if ability.bundles.count > 1 {
            presentBundleSelection(ability: ability, agent: row.agent)
        } else {
            extend(ability: ability, agent: row.agent, bundleIds: defaultBundleIds(for: ability))
        }
    }

    private func withdraw(ability: AbilitiesAPI.Ability, agent: ConversationAgentDescriptor) {
        isBusy = true
        errorMessage = nil
        let task = Task {
            var mutationError: String?
            do {
                try await service.withdrawAbility(
                    conversationId: conversationId,
                    abilityId: ability.id,
                    agentInboxId: agent.inboxId
                )
                // Mirrors the extend-side announcement, including through
                // the service's benign not-found path — a stale announced
                // grant must not outlive a withdrawal.
                await selection.announcer?.announceDisabled(
                    conversationId: conversationId,
                    agentInboxId: agent.inboxId,
                    abilityId: ability.id
                )
            } catch {
                mutationError = error.localizedDescription
            }
            isBusy = false
            await refresh()
            onOptInsMutated?()
            if let mutationError {
                errorMessage = mutationError
            }
        }
        mutationTask = task
    }

    /// The bundles a plain toggle-on grants: the manifest's
    /// default-enabled set, or every bundle when the manifest marks none
    /// as default (a single opt-out bundle still needs to grant something).
    private func defaultBundleIds(for ability: AbilitiesAPI.Ability) -> [String] {
        let defaults: [String] = ability.bundles.filter(\.defaultEnabled).map(\.id)
        guard defaults.isEmpty else { return defaults }
        return ability.bundles.map(\.id)
    }

    private func rebuildRows() {
        guard let catalog else {
            builtRows = []
            return
        }
        let sortedAbilities: [AbilitiesAPI.Ability] = catalog.abilities.sorted { (lhs: AbilitiesAPI.Ability, rhs: AbilitiesAPI.Ability) -> Bool in
            lhs.displayName.resolved().localizedCaseInsensitiveCompare(rhs.displayName.resolved()) == .orderedAscending
        }
        let authoritative: [ConversationAbility]? = optIns.authoritativeValues
        let optedIn: Set<ConversationAbilityKey> = Set((authoritative ?? []).map(\.key))
        let hasSettledOptIn: Bool = authoritative != nil
        var built: [Row] = []
        for ability in sortedAbilities {
            for agent in agents {
                let key = ConversationAbilityKey(abilityId: ability.id, agentInboxId: agent.inboxId)
                let isPending: Bool = pendingEnablement.contains(key)
                let isOn: Bool = optedIn.contains(key) || isPending
                let rowLifecycle: Row.Lifecycle = lifecycle(for: ability, isOptedIn: isOn)
                built.append(Row(
                    ability: ability,
                    agent: agent,
                    isOn: isOn,
                    lifecycle: rowLifecycle,
                    hasSettledOptIn: hasSettledOptIn,
                    isPendingEnablement: isPending
                ))
            }
        }
        builtRows = built
    }

    /// Derives row usability from both the opt-in and the entitlement
    /// lifecycle. An existing opt-in backed by anything other than an
    /// active entitlement needs attention; it never reads as usable.
    private func lifecycle(for ability: AbilitiesAPI.Ability, isOptedIn: Bool) -> Row.Lifecycle {
        switch ability.entitlementState {
        case .entitled(let entitlement) where entitlement.status == .active:
            return .ready
        case .entitled(let entitlement):
            return isOptedIn ? .needsAttention(entitlement.status) : .needsEntitlement
        case .notEntitled:
            return isOptedIn ? .needsAttention(nil) : .needsEntitlement
        case .unknown:
            return .unknown
        }
    }
}
