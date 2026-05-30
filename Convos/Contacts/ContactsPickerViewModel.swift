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
    /// First step of the compose flow (`ComposeFlowView`): the picker is the
    /// root of the host navigation stack and selecting contacts is optional
    /// (the CTA reads "Skip" with an empty selection), then the new
    /// conversation is pushed rather than presented.
    case compose
    case addToConversation(conversationId: String, conversationTitle: String?)

    var isAddToConversation: Bool {
        switch self {
        case .newConversation, .compose:
            return false
        case .addToConversation:
            return true
        }
    }

    var isCompose: Bool {
        if case .compose = self { return true }
        return false
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
        // Compose always allows proceeding (selection is optional - "Skip"
        // creates an empty draft); other modes need at least one contact.
        switch mode {
        case .compose:
            return true
        case .newConversation, .addToConversation:
            return !selectedInboxIds.isEmpty
        }
    }

    var headerTitle: String {
        switch mode {
        case .newConversation, .compose:
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
        case .newConversation, .compose:
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
        if case .compose = mode, selectedInboxIds.isEmpty {
            return "Skip"
        }
        return "Continue"
    }

    // MARK: - Mutations

    func toggleSelection(for inboxId: String) {
        guard !alreadyInChatInboxIds.contains(inboxId) else { return }
        if selectedInboxIds.contains(inboxId) {
            selectedInboxIds.remove(inboxId)
        } else {
            // At most one agent per conversation - agents are
            // instance-per-conversation and can't share context. Once one
            // is selected, other agent rows are disabled (see
            // `isAgentSelectionBlocked`); selecting a second is a no-op.
            // Humans are unrestricted.
            if isAgent(inboxId), selectedAgentInboxId != nil {
                return
            }
            selectedInboxIds.insert(inboxId)
        }
    }

    /// True when `inboxId` is an unselected agent that can't be selected
    /// because a different agent is already selected. The picker disables
    /// these rows; the user deselects the current agent to pick another.
    func isAgentSelectionBlocked(for inboxId: String) -> Bool {
        guard isAgent(inboxId), !selectedInboxIds.contains(inboxId) else { return false }
        return selectedAgentInboxId != nil
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

    /// `inboxId` of the currently selected agent, if any. At most one
    /// agent may be selected (see `toggleSelection`).
    var selectedAgentInboxId: String? {
        selectedInboxIds.first { isAgent($0) }
    }

    /// `agentTemplateId` of the currently selected agent, threaded into
    /// conversation creation so a fresh instance of that template is
    /// spawned into the new (or existing) conversation.
    var selectedAgentTemplateId: String? {
        guard let agentInboxId = selectedAgentInboxId else { return nil }
        return allContacts.first { $0.inboxId == agentInboxId }?.agentTemplateId
    }

    private func isAgent(_ inboxId: String) -> Bool {
        allContacts.first { $0.inboxId == inboxId }?.agentTemplateId != nil
    }

    /// Single source of truth for "is this contact a valid picker row".
    /// A contact is pickable when it shows in the Contacts browse list
    /// (`isVisibleInContactsList`: template-backed agents and named humans)
    /// and the user hasn't blocked it. Blocked contacts stay in the browse
    /// list so they can be unblocked, but they are never a valid picker
    /// target. Template-backed agents are selectable in every mode, since
    /// starting (or adding to) a conversation spawns a fresh instance.
    static func isPickable(_ contact: Contact) -> Bool {
        !contact.isBlocked && contact.isVisibleInContactsList
    }

    /// Contacts selectable in the picker, used by `ConversationsViewModel` to
    /// size its compose entry point.
    static func pickableContacts(_ contacts: [Contact]) -> [Contact] {
        contacts.filter(isPickable)
    }

    // MARK: - Section building

    private func applyContacts(_ contacts: [Contact]) {
        allContacts = contacts
        // Prune selections to what's actually pickable. Pruning against the
        // *visible* set (not just the known set) drops phantom selections --
        // a preselected inboxId for a contact who's hidden because they're
        // blocked / a verified agent / unnamed would otherwise stay in
        // `selectedInboxIds`, counting toward `selectionCount` and passing
        // `canConfirm` with no UI for the user to remove it.
        let visibleInboxIds = Set(allContacts.filter(Self.isPickable).map(\.inboxId))
        selectedInboxIds = selectedInboxIds.intersection(visibleInboxIds)
        rebuildSections()
        isLoading = false
    }

    private func rebuildSections() {
        let visible = allContacts.filter(Self.isPickable)
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
