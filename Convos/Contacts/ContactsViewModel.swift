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
        // the compose button's enabled flag. Count what's actually visible
        // in the list -- verified agents are hidden from this view, and
        // unnamed contacts are filtered out below in `rebuildSections`,
        // so include both predicates here too.
        contactCount = contacts.filter(Self.isVisibleInList).count
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

    /// Recomputes `sections` from `allContacts` honoring the current
    /// `searchQuery`. Mirrors the picker's filter/group pipeline so both
    /// surfaces sort and bucket identically.
    private func rebuildSections() {
        let visibleContacts = allContacts.filter(Self.isVisibleInList)
        let filtered = filterByQuery(visibleContacts)
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
