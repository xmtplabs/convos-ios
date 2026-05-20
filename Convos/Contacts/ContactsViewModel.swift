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
        let contacts: [Contact]
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
        // the compose button's enabled flag. Use the human-visible count
        // (verified agents are hidden from this view) so a user whose
        // contacts are all agents sees the empty state correctly.
        contactCount = contacts.filter { !$0.isVerifiedAgent }.count
        rebuildSections()
        isLoading = false
    }

    /// Recomputes `sections` from `allContacts` honoring the current
    /// `searchQuery`. Mirrors the picker's filter/group pipeline so both
    /// surfaces sort and bucket identically.
    ///
    /// Verified agents are kept in `DBContact` so chat-side surfaces (member
    /// rows, system messages, the contact card opened from a member tap) can
    /// still resolve their profile; they are excluded here so the human
    /// contact browser stays focused on real people.
    private func rebuildSections() {
        let visibleContacts = allContacts.filter { !$0.isVerifiedAgent }
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
        sections = sortedKeys.map { key in
            Section(id: key, title: key, contacts: grouped[key] ?? [])
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
