import ConvosCore
import Foundation
import Observation

/// Drives the connection detail screen: where one connection is in use --
/// the agents holding it, the people it has been delegated to, and the
/// conversations it is enabled in. Pull-only: the sections refresh on
/// appear, matching how `ConversationAbilitiesViewModel.refresh()` works.
///
/// People always leads with the owner's own row and holds nothing else for
/// now (see `ConnectionUsage.people`); delegated people append below it
/// once the Entitlement Actor Model lands, so filling the section is a
/// change of source, not of screen.
@MainActor @Observable
final class AbilityDetailViewModel {
    let ability: AbilitiesAPI.Ability

    private(set) var usage: ConnectionUsage = .empty
    /// True when the read reached nothing: either the conversation list
    /// itself failed, or every conversation refused. The sections then say
    /// they could not check rather than reporting that nothing uses the
    /// connection.
    private(set) var isUnavailable: Bool = false
    private(set) var isLoading: Bool = false
    private(set) var hasLoadedOnce: Bool = false

    private let usageSource: any ConnectionUsageSourcing

    init(ability: AbilitiesAPI.Ability, usageSource: any ConnectionUsageSourcing) {
        self.ability = ability
        self.usageSource = usageSource
    }

    var agents: [ConnectionUsageAgent] { usage.agents }
    /// The owner always leads, so the section is never empty; delegated
    /// people append below once anything writes them.
    var people: [ConnectionUsagePerson] { [.owner] + usage.people }
    var conversations: [ConnectionUsageConversation] { usage.conversations }

    func refresh() async {
        isLoading = true
        let snapshot: ConnectionUsageSnapshot = await usageSource.usageSnapshot()
        usage = snapshot.usage(forAbilityId: ability.id)
        isUnavailable = snapshot.isUnavailable
        isLoading = false
        hasLoadedOnce = true
    }
}
