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
    }

    var sections: [Section] = []
    var contactCount: Int = 0
    var isLoading: Bool = true
    var searchQuery: String = "" {
        didSet { rebuildSections() }
    }
    /// "Show blocked" toggle from the search bar's filter menu. Defaults to
    /// `false` so blocked contacts are hidden from the browse list by default;
    /// when enabled, blocked contacts appear inline (the contact card is the
    /// unblock entry point).
    var showBlocked: Bool = false {
        didSet { rebuildSections() }
    }
    /// True when a text search or the show-blocked toggle is narrowing the
    /// list. An empty `sections` while filtering means "nothing matched", which
    /// the view distinguishes from the "no contacts yet" onboarding empty
    /// state.
    var isFiltering: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    init(contactsRepository: any ContactsRepositoryProtocol) {
        self.contactsRepository = contactsRepository

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

    /// Single source of truth for "is this contact rendered in the list",
    /// which `contactCount` also counts so the count and the list agree.
    ///
    /// People only. Agents stay in `DBContact` so chat-side surfaces resolve
    /// them, and the contacts picker still offers them when starting a
    /// conversation; they are simply not something you browse here.
    static func isVisibleInList(_ contact: Contact) -> Bool {
        guard !contact.isAgent else { return false }
        return contact.isVisibleInContactsList
    }

    private func visibleContacts() -> [Contact] {
        allContacts.filter(Self.isVisibleInList)
    }

    /// Recomputes `sections` from `allContacts` honoring the current
    /// `searchQuery`. Mirrors the picker's filter/group pipeline so both
    /// surfaces sort and bucket identically.
    private func rebuildSections() {
        let filtered = filterByQuery(filterByBlocked(visibleContacts()))
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
        let rebuilt: [Section] = sortedKeys.map { key in
            let rows = (grouped[key] ?? []).map { contact in
                Row(id: contact.inboxId, contact: contact, subtitle: contact.listSubtitle(sources: sources))
            }
            return Section(id: key, title: key, rows: rows)
        }

        sections = rebuilt
    }

    private func filterByQuery(_ contacts: [Contact]) -> [Contact] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contacts }
        return contacts.filter { contact in
            contact.resolvedDisplayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Drops blocked contacts unless `showBlocked` is on, before the search
    /// predicate runs so it sees the post-blocked set.
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
        showBlocked = false
    }
}
