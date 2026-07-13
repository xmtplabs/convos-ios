import Combine
import ConvosCore
import Foundation
import Observation

/// View model backing the Contacts list browse screen. Subscribes to the
/// repository's reactive publisher and groups the contacts into alphabetical
/// sections for rendering.
@Observable
@MainActor
final class ContactsViewModel {
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
        /// True for rows in the trailing "Suggested agents" section (featured
        /// agent templates, not the user's own contacts). Drives the load-more
        /// trigger when the last such row appears.
        var isSuggestedAgent: Bool = false
    }

    var sections: [Section] = []
    var contactCount: Int = 0
    var isLoading: Bool = true
    var searchQuery: String = "" {
        didSet { rebuildSections() }
    }
    /// Audience filter toggled from the search bar's filter menu. Narrows the
    /// list to people or agents; `contactCount` stays unfiltered so a filter
    /// that matches nothing renders an empty list rather than the "no contacts"
    /// onboarding empty state.
    var filter: ContactsFilter = .all {
        didSet { rebuildSections() }
    }
    /// "Show blocked" toggle from the search bar's filter menu. Defaults to
    /// `false` so blocked contacts are hidden from the browse list by default;
    /// when enabled, blocked contacts appear inline (the contact card is the
    /// unblock entry point).
    var showBlocked: Bool = false {
        didSet { rebuildSections() }
    }
    /// True while the initial suggested-agents page request is in flight.
    var isLoadingSuggestedAgents: Bool {
        suggestedAgentsModel.isLoading
    }
    /// True when a text search, audience filter, or the show-blocked toggle is
    /// narrowing the list. An empty `sections` while filtering means "nothing
    /// matched", which the view distinguishes from the "no contacts yet"
    /// onboarding empty state.
    var isFiltering: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || filter.isActive
            || showBlocked
    }

    private let contactsRepository: any ContactsRepositoryProtocol
    private var cancellable: AnyCancellable?
    private var allContacts: [Contact] = []
    /// True once the repository publisher has delivered a value; gates the
    /// best-effort initial fetch so it can't overwrite fresher data.
    private var hasReceivedContacts: Bool = false
    /// Source-conversation metadata for the "you met them in X" subtitles,
    /// keyed by conversation id. Refreshed off the main thread when the
    /// contact set changes; `rebuildSections()` reads only this cache so
    /// keystroke/filter changes never touch the database mid-render.
    private var sourceConversationsCache: [String: ContactSourceConversation] = [:]
    /// Monotonic token for in-flight source-conversation refreshes, so a
    /// slow older fetch can't overwrite the result of a newer one.
    private var sourceConversationsGeneration: Int = 0

    /// Shared suggested-agents fetch/pagination state. A nil service yields no
    /// section (e.g. previews that don't wire one).
    private let suggestedAgentsModel: SuggestedAgentsModel
    /// Synthetic contacts for the visible suggested agents, kept so the
    /// load-more trigger can recognize the last suggested row.
    private var suggestedAgentContacts: [Contact] = []

    init(
        contactsRepository: any ContactsRepositoryProtocol,
        suggestedAgentsService: (any SuggestedAgentsServiceProtocol)? = nil
    ) {
        self.contactsRepository = contactsRepository
        self.suggestedAgentsModel = SuggestedAgentsModel(service: suggestedAgentsService)

        suggestedAgentsModel.onAgentsChanged = { [weak self] in
            self?.rebuildSections()
        }

        cancellable = contactsRepository.contactsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] contacts in
                self?.hasReceivedContacts = true
                self?.applyContacts(contacts)
            }

        // Best-effort initial fetch for the first paint while the publisher
        // wires up its observation. Runs detached: this init happens during
        // SwiftUI body evaluation, and a synchronous read can stall for
        // seconds waiting on the database reader pool (app-hang
        // CONVOS-IOS-3T).
        Task.detached(priority: .userInitiated) { [weak self, contactsRepository] in
            guard let initial = try? contactsRepository.fetchAll() else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.hasReceivedContacts else { return }
                self.applyContacts(initial)
            }
        }
    }

    private func applyContacts(_ contacts: [Contact]) {
        allContacts = contacts
        // `contactCount` drives the empty-state vs list-state branch and
        // the compose button's enabled flag. Count the rows actually shown.
        // Agent instances are already collapsed to one canonical row per
        // template by `ContactsRepository`, so this only filters visibility.
        contactCount = visibleContacts().count
        rebuildSections()
        isLoading = false
        refreshSourceConversations()
    }

    /// Refreshes `sourceConversationsCache` for the current contact set, off
    /// the main thread. Rebuilds sections when the metadata actually changed
    /// so subtitles fill in as soon as the fetch lands.
    private func refreshSourceConversations() {
        let ids = Set(allContacts.compactMap { $0.addedViaConversationId })
        sourceConversationsGeneration += 1
        let generation = sourceConversationsGeneration
        Task.detached(priority: .userInitiated) { [weak self, contactsRepository = self.contactsRepository] in
            guard let sources = try? contactsRepository.sourceConversations(forIds: ids) else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      generation == self.sourceConversationsGeneration,
                      self.sourceConversationsCache != sources else { return }
                self.sourceConversationsCache = sources
                self.rebuildSections()
            }
        }
    }

    /// Contacts actually rendered in the browser list. Shared with other
    /// surfaces (e.g. the App Settings "Contacts" count) so they match what
    /// the list shows -- the raw contact count includes hidden / unnamed
    /// entries.
    static func visibleContacts(_ contacts: [Contact]) -> [Contact] {
        contacts.filter(isVisibleInList)
    }

    /// Single source of truth for "is this contact rendered in the list" -
    /// `Contact.isVisibleInContactsList`, shared with the App Settings
    /// "Contacts" badge so the count and the list always agree. Template-
    /// backed agents are surfaced as contacts; template-less verified agents
    /// and unnamed humans are hidden.
    static func isVisibleInList(_ contact: Contact) -> Bool {
        contact.isVisibleInContactsList
    }

    private func visibleContacts() -> [Contact] {
        allContacts.filter(Self.isVisibleInList)
    }

    /// Recomputes `sections` from `allContacts` honoring the current
    /// `searchQuery`. Mirrors the picker's filter/group pipeline so both
    /// surfaces sort and bucket identically.
    private func rebuildSections() {
        let filtered = filterByQuery(filterByAudience(filterByBlocked(visibleContacts())))
        let grouped: [String: [Contact]] = Dictionary(grouping: filtered) { $0.alphabeticalSectionKey }
        let sortedKeys = grouped.keys.sorted { lhs, rhs in
            // "#" sorts last so non-alpha names land after Z.
            switch (lhs, rhs) {
            case ("#", "#"): return false
            case ("#", _): return false
            case (_, "#"): return true
            default: return lhs < rhs
            }
        }
        let sources = sourceConversationsCache
        var rebuilt: [Section] = sortedKeys.map { key in
            let rows = (grouped[key] ?? []).map { contact in
                Row(id: contact.inboxId, contact: contact, subtitle: contact.listSubtitle(sources: sources))
            }
            return Section(id: key, title: key, rows: rows)
        }

        if let suggested = buildSuggestedAgentsSection() {
            rebuilt.append(suggested)
        }
        sections = rebuilt
    }

    /// Builds the trailing "Suggested agents" section (and refreshes
    /// `suggestedAgentContacts`). Returns nil when there's nothing to show, or
    /// while a search is active -- suggestions are a browse affordance and the
    /// server-paged list can't be filtered against a partial set on the client.
    private func buildSuggestedAgentsSection() -> Section? {
        let existingAgentTemplateIds = Set(allContacts.compactMap { $0.agentTemplateId })
        let visibleSuggested = suggestedAgentsModel.visibleAgents(excludingTemplateIds: existingAgentTemplateIds)

        let rows: [Row] = visibleSuggested.map { agent in
            let contact = Contact.suggestedAgent(agent)
            return Row(
                id: contact.inboxId,
                contact: contact,
                subtitle: agent.description ?? "",
                isSuggestedAgent: true
            )
        }
        suggestedAgentContacts = rows.map(\.contact)

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // Suggested agents are agents, so hide the whole section under the
        // People filter (and while a search is active).
        guard trimmedQuery.isEmpty, filter.includesAgents, !rows.isEmpty else { return nil }
        return Section(id: SuggestedAgentsSection.id, title: SuggestedAgentsSection.title, rows: rows)
    }

    private func filterByQuery(_ contacts: [Contact]) -> [Contact] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contacts }
        return contacts.filter { contact in
            contact.resolvedDisplayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func filterByAudience(_ contacts: [Contact]) -> [Contact] {
        guard filter.isActive else { return contacts }
        return contacts.filter { filter.includes($0) }
    }

    /// Drops blocked contacts unless `showBlocked` is on. Inserted between
    /// `visibleContacts()` and `filterByAudience` so audience and search
    /// predicates see the post-blocked set.
    private func filterByBlocked(_ contacts: [Contact]) -> [Contact] {
        guard !showBlocked else { return contacts }
        return contacts.filter { !$0.isBlocked }
    }

    /// Clears the active text search and audience filter so the full list is
    /// shown again. Backs the "Show all" button on the filtered empty state.
    /// Also turns the show-blocked toggle off so "Show all" means the same
    /// default rendering the user gets on first load.
    func clearFilters() {
        searchQuery = ""
        filter = .all
        showBlocked = false
    }

    // MARK: - Suggested agents

    /// Loads the first page of suggested agents the first time the list
    /// appears. Idempotent: safe to call from `.task` on every appear.
    func loadSuggestedAgentsIfNeeded() async {
        await suggestedAgentsModel.loadIfNeeded()
    }

    /// Loads the next page when the last suggested row scrolls into view.
    func suggestedAgentRowAppeared(id rowId: String) async {
        guard rowId == suggestedAgentContacts.last?.inboxId else { return }
        await suggestedAgentsModel.loadMore()
    }
}
