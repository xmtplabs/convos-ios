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

    var id: String { "\(ability.id)|\(agent.inboxId)" }
}

@MainActor @Observable
final class ConversationAbilitiesViewModel {
    /// One toggle: an ability crossed with one agent. Single-agent
    /// conversations produce exactly one row per ability.
    struct Row: Identifiable, Hashable {
        let ability: AbilitiesAPI.Ability
        let agent: ConversationAgentDescriptor
        let isOn: Bool

        var id: String { "\(ability.id)|\(agent.inboxId)" }
    }

    private(set) var rows: [Row] = []
    private(set) var isBusy: Bool = false
    private(set) var errorMessage: String?
    /// Non-nil presents the bundle picker sheet.
    var bundleSelection: AbilityBundleSelectionContext?
    /// Non-nil presents the abilities list sheet: the tapped ability has no
    /// active entitlement, so the user connects it there first.
    var needsEntitlementAbility: AbilitiesAPI.Ability?

    private var catalog: AbilitiesAPI.CatalogResponse?
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
        if row.isOn {
            withdraw(ability: row.ability, agent: row.agent)
        } else {
            requestExtension(for: row)
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
        let sortedAbilities: [AbilitiesAPI.Ability] = catalog.abilities.sorted { lhs, rhs in
            lhs.displayName.resolved().localizedCaseInsensitiveCompare(rhs.displayName.resolved()) == .orderedAscending
        }
        let optedIn: Set<String> = Set(optIns.map { "\($0.abilityId)|\($0.agentInboxId)" })
        var built: [Row] = []
        for ability in sortedAbilities {
            for agent in agents {
                let isOn = optedIn.contains("\(ability.id)|\(agent.inboxId)")
                built.append(Row(ability: ability, agent: agent, isOn: isOn))
            }
        }
        rows = built
    }
}
