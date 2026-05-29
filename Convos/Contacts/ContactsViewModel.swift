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

    private let contactsRepository: any ContactsRepositoryProtocol
    private var cancellable: AnyCancellable?
    private var allContacts: [Contact] = []

    init(contactsRepository: any ContactsRepositoryProtocol) {
        self.contactsRepository = contactsRepository

        cancellable = contactsRepository.contactsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] contacts in
                self?.applyContacts(contacts)
            }

        // Best-effort initial fetch for the first paint while the publisher
        // wires up its observation.
        if let initial = try? contactsRepository.fetchAll() {
            applyContacts(initial)
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
        let filtered = filterByQuery(visibleContacts())
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
        let viaIds: Set<String> = Set(filtered.compactMap { $0.addedViaConversationId })
        let sources: [String: ContactSourceConversation] = (try? contactsRepository.sourceConversations(forIds: viaIds)) ?? [:]
        sections = sortedKeys.map { key in
            let rows = (grouped[key] ?? []).map { contact in
                Row(id: contact.inboxId, contact: contact, subtitle: contact.listSubtitle(sources: sources))
            }
            return Section(id: key, title: key, rows: rows)
        }
    }

    private func filterByQuery(_ contacts: [Contact]) -> [Contact] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contacts }
        return contacts.filter { contact in
            contact.resolvedDisplayName.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
