import Combine
import ConvosCore
import Foundation
import Observation

/// Mode parameterizes the picker for either creating a new conversation or
/// scoping the selection to add members to an existing chat. The mode drives
/// the title, the bottom CTA copy, and the inline-disabled "in chat"
/// treatment for members already in the destination conversation.
///
/// Mirrors `ContactDetailMode`'s "one view, multiple entry points" pattern.
/// When introducing a similar surface elsewhere in the app, prefer this
/// shape (mode enum + parameterized view) over duplicating the view.
enum ContactsPickerMode: Hashable {
    case newConversation
    case addToConversation(conversationId: String, conversationTitle: String?)

    var isAddToConversation: Bool {
        switch self {
        case .newConversation:
            return false
        case .addToConversation:
            return true
        }
    }
}

/// View model backing the contact picker. Subscribes to the contacts
/// repository, drops blocked contacts, applies search filtering, groups the
/// result into alphabetical sections, and tracks the selected inboxIds.
@Observable
@MainActor
final class ContactsPickerViewModel {
    struct Section: Identifiable, Hashable {
        let id: String
        let title: String
        let rows: [Row]
    }

    struct Row: Identifiable, Hashable {
        let id: String
        let contact: Contact
        let isAlreadyInChat: Bool
        /// Caption rendered under the contact name. Resolves to the name of
        /// the conversation that promoted the inbox to a contact, falling
        /// back to the agent role label (for verified agents) or "DM" (no
        /// group convo name available).
        let subtitle: String
    }

    let mode: ContactsPickerMode
    var sections: [Section] = []
    var selectedInboxIds: Set<String> = []
    var searchQuery: String = "" {
        didSet { rebuildSections() }
    }
    var isLoading: Bool = true

    private let contactsRepository: any ContactsRepositoryProtocol
    private let alreadyInChatInboxIds: Set<String>
    private var allContacts: [Contact] = []
    private var cancellable: AnyCancellable?

    init(
        mode: ContactsPickerMode,
        contactsRepository: any ContactsRepositoryProtocol,
        alreadyInChatInboxIds: Set<String> = [],
        preselectedInboxIds: Set<String> = []
    ) {
        self.mode = mode
        self.contactsRepository = contactsRepository
        self.alreadyInChatInboxIds = alreadyInChatInboxIds
        self.selectedInboxIds = preselectedInboxIds.subtracting(alreadyInChatInboxIds)

        cancellable = contactsRepository.contactsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] contacts in
                self?.applyContacts(contacts)
            }

        if let initial = try? contactsRepository.fetchAll() {
            applyContacts(initial)
        }
    }

    // MARK: - Derived state

    var selectedContacts: [Contact] {
        allContacts.filter { selectedInboxIds.contains($0.inboxId) }
    }

    var selectionCount: Int {
        selectedInboxIds.count
    }

    var canConfirm: Bool {
        !selectedInboxIds.isEmpty
    }

    var headerTitle: String {
        switch mode {
        case .newConversation:
            return "New conversation"
        case .addToConversation(_, let title):
            if let title, !title.isEmpty {
                return "Add to \(title)"
            }
            return "Add to convo"
        }
    }

    /// Top-line text for the indicator pill. "New convo" while assembling
    /// a fresh conversation; existing convo name (or "Add to convo") when
    /// the picker is scoped to an existing chat.
    var pillTitle: String {
        switch mode {
        case .newConversation:
            return "New Convo"
        case .addToConversation(_, let title):
            if let title, !title.isEmpty {
                return title
            }
            return "Add to convo"
        }
    }

    /// Subtitle below the title in the indicator pill. Reads "Draft" when
    /// the user hasn't picked anyone yet, then transitions to "N selected"
    /// once they start picking. Identical wording across both modes — the
    /// title already disambiguates the intent.
    var pillSubtitle: String {
        if selectionCount == 0 {
            return "Draft"
        }
        return "\(selectionCount) selected"
    }

    var confirmButtonTitle: String {
        "Continue"
    }

    // MARK: - Mutations

    func toggleSelection(for inboxId: String) {
        guard !alreadyInChatInboxIds.contains(inboxId) else { return }
        if selectedInboxIds.contains(inboxId) {
            selectedInboxIds.remove(inboxId)
        } else {
            selectedInboxIds.insert(inboxId)
        }
    }

    func deselect(inboxId: String) {
        selectedInboxIds.remove(inboxId)
    }

    func clearSelection() {
        selectedInboxIds.removeAll()
    }

    func isSelected(inboxId: String) -> Bool {
        selectedInboxIds.contains(inboxId)
    }

    // MARK: - Section building

    private func applyContacts(_ contacts: [Contact]) {
        allContacts = contacts
        // Prune selections that no longer exist in the contact list.
        let known = Set(contacts.map(\.inboxId))
        selectedInboxIds = selectedInboxIds.intersection(known)
        rebuildSections()
        isLoading = false
    }

    private func rebuildSections() {
        // Verified agents are kept in `DBContact` so chat-side surfaces can
        // resolve them, but are hidden from the picker so users only see
        // human candidates when starting / adding to a conversation.
        let visible = allContacts.filter { !$0.isBlocked && !$0.isVerifiedAgent }
        let filtered = filterByQuery(visible)
        let grouped: [String: [Contact]] = Dictionary(
            grouping: filtered,
            by: { $0.alphabeticalSectionKey }
        )
        let sortedKeys = grouped.keys.sorted(by: Self.sectionKeyOrder)

        // Batched read of source-conversation metadata so each row's subtitle
        // can show the convo the user met the contact in. Missing entries
        // (deleted convo, never-recorded source) fall through to the agent
        // label or empty in the subtitle resolver below.
        let viaIds: Set<String> = Set(filtered.compactMap { $0.addedViaConversationId })
        let sources: [String: ContactSourceConversation] = (try? contactsRepository.sourceConversations(forIds: viaIds)) ?? [:]

        sections = sortedKeys.map { key in
            let rows = (grouped[key] ?? []).map { contact in
                Row(
                    id: contact.inboxId,
                    contact: contact,
                    isAlreadyInChat: alreadyInChatInboxIds.contains(contact.inboxId),
                    subtitle: contact.listSubtitle(sources: sources)
                )
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

    private static func sectionKeyOrder(_ lhs: String, _ rhs: String) -> Bool {
        switch (lhs, rhs) {
        case ("#", "#"): return false
        case ("#", _): return false
        case (_, "#"): return true
        default: return lhs < rhs
        }
    }
}
