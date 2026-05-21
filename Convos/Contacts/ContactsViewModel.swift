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
    }

    struct Section: Identifiable, Hashable {
        let id: String
        let title: String
        let rows: [Row]
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

    private func recompute() {
        // Verified human-agent rows stay hidden (chat-side surfaces still
        // resolve them from `DBContact`); agent-template contacts live in a
        // separate table and are always shown. `contactCount` drives the
        // empty-state branch, so it counts everything the list renders.
        let visibleHumanCount: Int = allContacts.filter { !$0.isVerifiedAgent }.count
        contactCount = visibleHumanCount + allAgentContacts.count
        rebuildSections()
        isLoading = false
    }

    /// Recomputes `sections` from `allContacts` + `allAgentContacts`
    /// honoring the current `searchQuery`. Humans and agent-template
    /// contacts are merged and bucketed into shared alphabetical sections.
    private func rebuildSections() {
        let humanItems: [ListItem] = allContacts
            .filter { !$0.isVerifiedAgent }
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
            let rows = (grouped[key] ?? []).map { contact in
                Row(id: contact.inboxId, contact: contact, subtitle: contact.listSubtitle(sources: sources))
            }
            return Section(id: key, title: key, rows: rows)
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
