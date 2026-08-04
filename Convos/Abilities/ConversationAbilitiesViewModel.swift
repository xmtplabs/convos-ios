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

        var id: ConversationAbilityKey {
            ConversationAbilityKey(abilityId: ability.id, agentInboxId: agent.inboxId)
        }
    }

    private(set) var rows: [Row] = []
    private(set) var isBusy: Bool = false
    private(set) var errorMessage: String?
    /// Non-nil presents the bundle picker sheet.
    var bundleSelection: AbilityBundleSelectionContext?
    /// Non-nil presents the inline connect sheet: the tapped ability has no
    /// active entitlement, so the user connects (or reconnects) it right
    /// here instead of detouring through App Settings.
    var connectContext: ConversationAbilityConnectContext?
    /// Parked continuation for a connect that succeeded: the connect sheet
    /// finishes dismissing first, then `handleConnectSheetDismissed` flows
    /// into the extension, so the bundle picker never races the dismissal.
    private var pendingExtensionAfterConnect: ConversationAbilityConnectContext?

    private var catalog: AbilitiesCatalog?
    private var optIns: [ConversationAbility] = []

    private let conversationId: String
    private let agents: [ConversationAgentDescriptor]
    /// The (service, authorizer) pair latched at construction; both halves
    /// travel together so the needs-entitlement sheet can never mix modes.
    private let selection: AbilitiesSelection

    private var service: any AbilitiesServiceProtocol { selection.service }

    init(
        conversationId: String,
        agents: [ConversationAgentDescriptor],
        selection: AbilitiesSelection
    ) {
        self.conversationId = conversationId
        self.agents = agents
        self.selection = selection
        refreshSoon()
    }

    var isSingleAgent: Bool {
        agents.count == 1
    }

    func refreshSoon() {
        Task { await refresh() }
    }

    func refresh() async {
        // Fetch both halves before committing either: publishing a fresh
        // catalog with stale or empty opt-ins would render opted-in rows
        // as off, and toggling one on would then overwrite the agent's
        // real bundle selection with defaults.
        do {
            let fetchedCatalog = try await service.fetchCatalog()
            let fetchedOptIns = try await service.conversationAbilities(conversationId: conversationId)
            catalog = fetchedCatalog
            optIns = fetchedOptIns
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        rebuildRows()
    }

    func toggle(_ row: Row) {
        guard !isBusy else { return }
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

    /// Presents the inline connect sheet for a row without a usable
    /// entitlement. Rows not yet opted in continue into the extension after
    /// a successful connect; already-opted-in rows (needs-attention) only
    /// repair the entitlement, since their opt-in and bundle selection
    /// already stand.
    func presentConnect(for row: Row) {
        connectContext = ConversationAbilityConnectContext(
            ability: row.ability,
            agent: row.agent,
            continuesToExtension: !row.isOn,
            preselectedBundleIds: nil
        )
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
            bundleSelection = AbilityBundleSelectionContext(ability: ability, agent: context.agent)
        } else {
            extend(ability: ability, agent: context.agent, bundleIds: defaultBundleIds(for: ability))
        }
    }

    /// Extends `ability` to `agent` with an explicit bundle selection
    /// (called by the bundle picker sheet's confirm).
    func extend(ability: AbilitiesAPI.Ability, agent: ConversationAgentDescriptor, bundleIds: [String]) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            var mutationError: String?
            do {
                try await service.extendAbility(
                    conversationId: conversationId,
                    abilityId: ability.id,
                    agentInboxId: agent.inboxId,
                    bundleIds: bundleIds
                )
            } catch AbilitiesServiceError.needsEntitlement {
                // The server says the entitlement is gone mid-extend: run
                // the connect inline and retry with the bundles the user
                // already chose, instead of re-opening the picker.
                connectContext = ConversationAbilityConnectContext(
                    ability: ability,
                    agent: agent,
                    continuesToExtension: true,
                    preselectedBundleIds: bundleIds
                )
            } catch {
                mutationError = error.localizedDescription
            }
            isBusy = false
            await refresh()
            // The refresh clears errorMessage on success; re-assert the
            // mutation failure so the bounced-back toggle is explained.
            if let mutationError {
                errorMessage = mutationError
            }
        }
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
            bundleSelection = AbilityBundleSelectionContext(ability: ability, agent: row.agent)
        } else {
            extend(ability: ability, agent: row.agent, bundleIds: defaultBundleIds(for: ability))
        }
    }

    private func withdraw(ability: AbilitiesAPI.Ability, agent: ConversationAgentDescriptor) {
        isBusy = true
        errorMessage = nil
        Task {
            var mutationError: String?
            do {
                try await service.withdrawAbility(
                    conversationId: conversationId,
                    abilityId: ability.id,
                    agentInboxId: agent.inboxId
                )
            } catch {
                mutationError = error.localizedDescription
            }
            isBusy = false
            await refresh()
            if let mutationError {
                errorMessage = mutationError
            }
        }
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
            rows = []
            return
        }
        let sortedAbilities: [AbilitiesAPI.Ability] = catalog.abilities.sorted { (lhs: AbilitiesAPI.Ability, rhs: AbilitiesAPI.Ability) -> Bool in
            lhs.displayName.resolved().localizedCaseInsensitiveCompare(rhs.displayName.resolved()) == .orderedAscending
        }
        let optedIn: Set<ConversationAbilityKey> = Set(optIns.map(\.key))
        var built: [Row] = []
        for ability in sortedAbilities {
            for agent in agents {
                let key = ConversationAbilityKey(abilityId: ability.id, agentInboxId: agent.inboxId)
                let isOn = optedIn.contains(key)
                let rowLifecycle: Row.Lifecycle = lifecycle(for: ability, isOptedIn: isOn)
                built.append(Row(ability: ability, agent: agent, isOn: isOn, lifecycle: rowLifecycle))
            }
        }
        rows = built
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
