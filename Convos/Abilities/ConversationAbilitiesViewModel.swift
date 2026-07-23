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
    /// Non-nil presents the abilities list sheet: the tapped ability has no
    /// active entitlement, so the user connects or reconnects it there.
    var needsEntitlementAbility: AbilitiesAPI.Ability?

    private var catalog: AbilitiesCatalog?
    private var optIns: [ConversationAbility] = []

    private let conversationId: String
    private let agents: [ConversationAgentDescriptor]
    private let service: any AbilitiesServiceProtocol

    init(
        conversationId: String,
        agents: [ConversationAgentDescriptor],
        service: any AbilitiesServiceProtocol
    ) {
        self.conversationId = conversationId
        self.agents = agents
        self.service = service
        refreshSoon()
    }

    var isSingleAgent: Bool {
        agents.count == 1
    }

    func refreshSoon() {
        Task { await refresh() }
    }

    func refresh() async {
        do {
            catalog = try await service.fetchCatalog()
            optIns = try await service.conversationAbilities(conversationId: conversationId)
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
            needsEntitlementAbility = row.ability
        case .unknown:
            break
        }
    }

    /// Extends `ability` to `agent` with an explicit bundle selection
    /// (called by the bundle picker sheet's confirm).
    func extend(ability: AbilitiesAPI.Ability, agent: ConversationAgentDescriptor, bundleIds: [String]) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            do {
                try await service.extendAbility(
                    conversationId: conversationId,
                    abilityId: ability.id,
                    agentInboxId: agent.inboxId,
                    bundleIds: bundleIds
                )
            } catch AbilitiesServiceError.needsEntitlement {
                needsEntitlementAbility = ability
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
            await refresh()
        }
    }

    /// Factory for the needs-entitlement deep link: the abilities list
    /// presented in a sheet, driven by the same service so a connect there
    /// is visible here after dismissal.
    func makeAbilitiesListViewModel() -> AbilitiesListViewModel {
        AbilitiesListViewModel(service: service)
    }

    private func requestExtension(for row: Row) {
        let ability = row.ability
        guard ability.entitlement?.status == .active else {
            needsEntitlementAbility = ability
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
            do {
                try await service.withdrawAbility(
                    conversationId: conversationId,
                    abilityId: ability.id,
                    agentInboxId: agent.inboxId
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
            await refresh()
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
