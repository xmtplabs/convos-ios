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

/// View model backing the contact picker. Subscribes to both the human and
/// the agent-template contact repositories, drops blocked humans, applies
/// search filtering, groups the merged result into alphabetical sections,
/// and tracks a heterogeneous selection of inboxIds and templateIds.
@Observable
@MainActor
final class ContactsPickerViewModel {
    /// A single picked entity. Heterogeneous so a session can spawn agents
    /// alongside inviting humans in one confirm.
    enum Selection: Hashable {
        case human(inboxId: String)
        case agentTemplate(templateId: String)

        var inboxId: String? {
            if case .human(let id) = self { return id }
            return nil
        }

        var templateId: String? {
            if case .agentTemplate(let id) = self { return id }
            return nil
        }
    }

    struct Section: Identifiable, Hashable {
        let id: String
        let title: String
        let rows: [Row]
    }

    /// Row backing a picker cell. The kind discriminator carries the full
    /// presentation model so cells can render human/agent affordances
    /// without re-fetching from the repository.
    struct Row: Identifiable, Hashable {
        let id: String
        let kind: Kind
        let isAlreadyInChat: Bool
        /// Caption rendered under the contact name. For humans this is the
        /// source conversation name / DM / agent role label resolver; for
        /// agent templates it's the template description.
        let subtitle: String

        enum Kind: Hashable {
            case human(Contact)
            case agentTemplate(AgentTemplateContact)
        }

        var selection: Selection {
            switch kind {
            case .human(let contact):
                return .human(inboxId: contact.inboxId)
            case .agentTemplate(let agent):
                return .agentTemplate(templateId: agent.templateId)
            }
        }

        var resolvedDisplayName: String {
            switch kind {
            case .human(let contact):
                return contact.resolvedDisplayName
            case .agentTemplate(let agent):
                return agent.resolvedDisplayName
            }
        }

        var alphabeticalSectionKey: String {
            switch kind {
            case .human(let contact):
                return contact.alphabeticalSectionKey
            case .agentTemplate(let agent):
                return agent.alphabeticalSectionKey
            }
        }
    }

    let mode: ContactsPickerMode
    var sections: [Section] = []
    var selected: Set<Selection> = []
    var searchQuery: String = "" {
        didSet { rebuildSections() }
    }
    var isLoading: Bool = true

    private let contactsRepository: any ContactsRepositoryProtocol
    private let agentTemplateContactsRepository: any AgentTemplateContactsRepositoryProtocol
    private let alreadyInChatInboxIds: Set<String>
    private var allContacts: [Contact] = []
    private var allAgentContacts: [AgentTemplateContact] = []
    private var cancellables: Set<AnyCancellable> = []

    init(
        mode: ContactsPickerMode,
        contactsRepository: any ContactsRepositoryProtocol,
        agentTemplateContactsRepository: any AgentTemplateContactsRepositoryProtocol
            = MockAgentTemplateContactsRepository(contacts: []),
        alreadyInChatInboxIds: Set<String> = [],
        preselectedInboxIds: Set<String> = []
    ) {
        self.mode = mode
        self.contactsRepository = contactsRepository
        self.agentTemplateContactsRepository = agentTemplateContactsRepository
        self.alreadyInChatInboxIds = alreadyInChatInboxIds
        let preselected: Set<Selection> = preselectedInboxIds
            .subtracting(alreadyInChatInboxIds)
            .map { Selection.human(inboxId: $0) }
            .reduce(into: Set<Selection>()) { $0.insert($1) }
        self.selected = preselected

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

        if let initialContacts = try? contactsRepository.fetchAll() {
            allContacts = initialContacts
        }
        if let initialAgentContacts = try? agentTemplateContactsRepository.fetchAll() {
            allAgentContacts = initialAgentContacts
        }
        rebuildSections()
    }

    // MARK: - Derived state

    var selectedContacts: [Contact] {
        let humanIds: Set<String> = selected.compactMap(\.inboxId).reduce(into: Set<String>()) { $0.insert($1) }
        return allContacts.filter { humanIds.contains($0.inboxId) }
    }

    var selectedAgentContacts: [AgentTemplateContact] {
        let templateIds: Set<String> = selected.compactMap(\.templateId).reduce(into: Set<String>()) { $0.insert($1) }
        return allAgentContacts.filter { templateIds.contains($0.templateId) }
    }

    var selectionCount: Int {
        selected.count
    }

    var canConfirm: Bool {
        !selected.isEmpty
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
    /// once they start picking. Identical wording across both modes - the
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

    func toggleSelection(_ selection: Selection) {
        if case .human(let inboxId) = selection, alreadyInChatInboxIds.contains(inboxId) {
            return
        }
        if selected.contains(selection) {
            selected.remove(selection)
        } else {
            selected.insert(selection)
        }
    }

    func deselect(_ selection: Selection) {
        selected.remove(selection)
    }

    func clearSelection() {
        selected.removeAll()
    }

    func isSelected(_ selection: Selection) -> Bool {
        selected.contains(selection)
    }

    // MARK: - Section building

    private func applyContacts(_ contacts: [Contact]) {
        allContacts = contacts
        pruneSelectionToKnownEntities()
        rebuildSections()
        isLoading = false
    }

    private func applyAgentContacts(_ agentContacts: [AgentTemplateContact]) {
        allAgentContacts = agentContacts
        pruneSelectionToKnownEntities()
        rebuildSections()
        isLoading = false
    }

    /// Single source of truth for "is this contact a valid picker row".
    /// Hidden from the picker:
    ///  - blocked contacts (the user explicitly opted out of contacting them)
    ///  - verified agents (kept in `DBContact` so chat-side surfaces can
    ///    resolve them, but not a valid picker target since they don't accept
    ///    1:1 DMs; agent rows have their own dedicated entry point)
    ///  - contacts whose displayName is missing/empty (would render as
    ///    "Somebody" via `resolvedDisplayName`; a name-less row isn't a
    ///    useful picker target -- there's nothing to distinguish one
    ///    "Somebody" from another)
    private static func isVisibleInPicker(_ contact: Contact) -> Bool {
        if contact.isBlocked || contact.isVerifiedAgent { return false }
        guard let name = contact.displayName, !name.isEmpty else { return false }
        return true
    }

    /// Drops selections whose underlying entity is either gone or no longer
    /// visible in the picker. Pruning against the *visible* set (not just
    /// the known set) drops phantom selections -- a preselected inboxId
    /// for a contact who's hidden (blocked / verified / unnamed) would
    /// otherwise stay in `selected`, counting toward `selectionCount` and
    /// passing `canConfirm` with no UI for the user to remove it.
    private func pruneSelectionToKnownEntities() {
        let visibleInboxIds: Set<String> = Set(
            allContacts.filter(Self.isVisibleInPicker).map(\.inboxId)
        )
        let knownTemplateIds: Set<String> = Set(allAgentContacts.map(\.templateId))
        selected = selected.filter { selection in
            switch selection {
            case .human(let inboxId):
                return visibleInboxIds.contains(inboxId)
            case .agentTemplate(let templateId):
                return knownTemplateIds.contains(templateId)
            }
        }
    }

    private func rebuildSections() {
        // Humans go through `isVisibleInPicker` (drops blocked, verified
        // agents, and unnamed rows). Agent-template contacts live in
        // their own table and are always shown.
        let visibleHumans: [Contact] = allContacts.filter(Self.isVisibleInPicker)
        let humanItems: [Row.Kind] = visibleHumans.map { .human($0) }
        let agentItems: [Row.Kind] = allAgentContacts.map { .agentTemplate($0) }
        let filtered: [Row.Kind] = filterByQuery(humanItems + agentItems)

        let grouped: [String: [Row.Kind]] = Dictionary(grouping: filtered) { kind in
            sectionKey(for: kind)
        }
        let sortedKeys = grouped.keys.sorted(by: Self.sectionKeyOrder)

        // Batched read of source-conversation metadata so each human row's
        // subtitle can show the convo the user met the contact in. Agent
        // rows skip this fetch (their subtitle is the template description).
        let viaIds: Set<String> = Set(
            filtered.compactMap { kind -> String? in
                if case .human(let contact) = kind {
                    return contact.addedViaConversationId
                }
                return nil
            }
        )
        let sources: [String: ContactSourceConversation] = (try? contactsRepository.sourceConversations(forIds: viaIds)) ?? [:]

        sections = sortedKeys.map { key in
            let rows = (grouped[key] ?? []).map { kind in
                makeRow(kind: kind, sources: sources)
            }
            return Section(id: key, title: key, rows: rows)
        }
    }

    private func makeRow(
        kind: Row.Kind,
        sources: [String: ContactSourceConversation]
    ) -> Row {
        switch kind {
        case .human(let contact):
            return Row(
                id: "human:\(contact.inboxId)",
                kind: kind,
                isAlreadyInChat: alreadyInChatInboxIds.contains(contact.inboxId),
                subtitle: contact.listSubtitle(sources: sources)
            )
        case .agentTemplate(let agent):
            return Row(
                id: "agent:\(agent.templateId)",
                kind: kind,
                isAlreadyInChat: false,
                subtitle: agent.descriptionText ?? ""
            )
        }
    }

    private func sectionKey(for kind: Row.Kind) -> String {
        switch kind {
        case .human(let contact):
            return contact.alphabeticalSectionKey
        case .agentTemplate(let agent):
            return agent.alphabeticalSectionKey
        }
    }

    private func filterByQuery(_ items: [Row.Kind]) -> [Row.Kind] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { kind in
            switch kind {
            case .human(let contact):
                return contact.resolvedDisplayName.localizedCaseInsensitiveContains(trimmed)
            case .agentTemplate(let agent):
                return agent.resolvedDisplayName.localizedCaseInsensitiveContains(trimmed)
            }
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
