import Combine
import ConvosCore
import Foundation
import Observation

/// View model backing the Contacts list browse screen. Subscribes to both
/// the human-contacts repository and the agent-template-contacts repository
/// and merges the two into shared alphabetical sections for rendering.
@Observable
@MainActor
final class ContactsViewModel {
    /// A single browsable row: either a human `Contact` or an
    /// `AgentTemplateContact`. The two live in separate tables - one keyed
    /// by `inboxId`, the other by `templateId` - and are merged here for
    /// the unified alphabetical list.
    enum ListItem: Identifiable, Hashable {
        case human(Contact)
        case agentTemplate(AgentTemplateContact)

        var id: String {
            switch self {
            case .human(let contact):
                return "human:\(contact.inboxId)"
            case .agentTemplate(let agent):
                return "agent:\(agent.templateId)"
            }
        }

        var resolvedDisplayName: String {
            switch self {
            case .human(let contact):
                return contact.resolvedDisplayName
            case .agentTemplate(let agent):
                return agent.resolvedDisplayName
            }
        }

        var alphabeticalSectionKey: String {
            switch self {
            case .human(let contact):
                return contact.alphabeticalSectionKey
            case .agentTemplate(let agent):
                return agent.alphabeticalSectionKey
            }
        }

        var addedViaConversationId: String? {
            switch self {
            case .human(let contact):
                return contact.addedViaConversationId
            case .agentTemplate(let agent):
                return agent.addedViaConversationId
            }
        }
    }

    /// Dual-shape section so two consumers can read the same data the way
    /// each expects: `rows` is humans-only (`Row` carries a `Contact`) for
    /// callers that pre-date the agent-template merge, and `items` is the
    /// merged list (`ListItem` sum) for agent-aware callers.
    struct Section: Identifiable, Hashable {
        let id: String
        let title: String
        let rows: [Row]
        let items: [ListItem]
    }

    struct Row: Identifiable, Hashable {
        let id: String
        let contact: Contact
        /// Same resolver as the picker — convo name, then "DM" for 1:1
        /// source, then agent role label, then empty (caller hides line).
        let subtitle: String
    }

    var sections: [Section] = []
    var contactCount: Int = 0
    var isLoading: Bool = true
    var searchQuery: String = "" {
        didSet { rebuildSections() }
    }

    private let contactsRepository: any ContactsRepositoryProtocol
    private let agentTemplateContactsRepository: any AgentTemplateContactsRepositoryProtocol
    private var cancellables: Set<AnyCancellable> = []
    private var allContacts: [Contact] = []
    private var allAgentContacts: [AgentTemplateContact] = []

    init(
        contactsRepository: any ContactsRepositoryProtocol,
        agentTemplateContactsRepository: any AgentTemplateContactsRepositoryProtocol
            = MockAgentTemplateContactsRepository(contacts: [])
    ) {
        self.contactsRepository = contactsRepository
        self.agentTemplateContactsRepository = agentTemplateContactsRepository

        contactsRepository.contactsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] contacts in
                self?.applyContacts(contacts)
            }
            .store(in: &cancellables)

        agentTemplateContactsRepository.agentTemplateContactsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agentContacts in
                self?.applyAgentContacts(agentContacts)
            }
            .store(in: &cancellables)

        // Best-effort initial fetch for the first paint while the
        // publishers wire up their observations.
        if let initialContacts = try? contactsRepository.fetchAll() {
            allContacts = initialContacts
        }
        if let initialAgentContacts = try? agentTemplateContactsRepository.fetchAll() {
            allAgentContacts = initialAgentContacts
        }
        recompute()
    }

    private func applyContacts(_ contacts: [Contact]) {
        allContacts = contacts
        recompute()
    }

    private func applyAgentContacts(_ agentContacts: [AgentTemplateContact]) {
        allAgentContacts = agentContacts
        recompute()
    }

    /// Shared recompute path triggered whenever either repository emits.
    /// `contactCount` drives the empty-state vs list-state branch and the
    /// compose button's enabled flag, so it counts everything the list
    /// renders: humans that pass `isVisibleInList` (named, non-verified)
    /// plus every agent-template contact.
    private func recompute() {
        let visibleHumanCount: Int = allContacts.filter(Self.isVisibleInList).count
        contactCount = visibleHumanCount + allAgentContacts.count
        rebuildSections()
        isLoading = false
    }

    /// Single source of truth for "is this contact rendered in the list".
    /// Verified agents stay in `DBContact` so chat-side surfaces (member
    /// rows, system messages, the contact card opened from a member tap)
    /// can still resolve them, but they're excluded here so the human
    /// contact browser stays focused on real people. Contacts whose
    /// displayName is missing/empty render as "Somebody" via
    /// `resolvedDisplayName`; a "Somebody" row carries no useful info
    /// for the browser, so we hide it until a profile name arrives.
    private static func isVisibleInList(_ contact: Contact) -> Bool {
        if contact.isVerifiedAgent { return false }
        guard let name = contact.displayName, !name.isEmpty else { return false }
        return true
    }

    /// Recomputes `sections` from `allContacts` + `allAgentContacts`
    /// honoring the current `searchQuery`. Humans (filtered through
    /// `isVisibleInList`) and agent-template contacts are merged and
    /// bucketed into shared alphabetical sections.
    private func rebuildSections() {
        let humanItems: [ListItem] = allContacts
            .filter(Self.isVisibleInList)
            .map { ListItem.human($0) }
        let agentItems: [ListItem] = allAgentContacts.map { ListItem.agentTemplate($0) }
        let filtered: [ListItem] = filterByQuery(humanItems + agentItems)

        let grouped: [String: [ListItem]] = Dictionary(grouping: filtered) { $0.alphabeticalSectionKey }
        let sortedKeys: [String] = grouped.keys.sorted { lhs, rhs in
            // "#" sorts last so non-alpha names land after Z.
            switch (lhs, rhs) {
            case ("#", "#"): return false
            case ("#", _): return false
            case (_, "#"): return true
            default: return lhs < rhs
            }
        }
        let viaIds: Set<String> = Set(filtered.compactMap { $0.addedViaConversationId })
        let sources: [String: ContactSourceConversation] = (try? contactsRepository.sourceConversations(forIds: viaIds)) ?? [:]
        sections = sortedKeys.map { key in
            let itemsInGroup: [ListItem] = grouped[key] ?? []
            let humansInGroup: [Contact] = itemsInGroup.compactMap { item in
                if case .human(let contact) = item { return contact }
                return nil
            }
            let rowsInGroup: [Row] = humansInGroup.map { contact in
                Row(id: contact.inboxId, contact: contact, subtitle: contact.listSubtitle(sources: sources))
            }
            return Section(id: key, title: key, rows: rowsInGroup, items: itemsInGroup)
        }
    }

    private func filterByQuery(_ items: [ListItem]) -> [ListItem] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            item.resolvedDisplayName.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
