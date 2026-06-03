import ConvosCore
import Foundation

/// Audience filter applied to the contact list shown by the Contacts browse
/// screen (`ContactsView`) and the contacts picker (`ContactsPickerView`).
/// Toggled from the filter affordance in `ContactsSearchBar` and applied where
/// each view model rebuilds its sections. People are humans; agents are
/// template-backed contacts (`agentTemplateId != nil`), matching the picker's
/// own agent discriminator.
enum ContactsFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case people
    case agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .people:
            return "People"
        case .agents:
            return "Agents"
        }
    }

    /// Whether the filter is narrowing the list. Drives the active-state
    /// treatment on the search bar's filter icon.
    var isActive: Bool {
        self != .all
    }

    /// Whether the agents audience is part of the current filter. Used to hide
    /// agent-only sections (e.g. "Suggested agents") under the People filter.
    var includesAgents: Bool {
        self != .people
    }

    /// Whether `contact` belongs to the current audience. Agents are
    /// template-backed (`agentTemplateId != nil`); everything else is a person.
    func includes(_ contact: Contact) -> Bool {
        switch self {
        case .all:
            return true
        case .people:
            return contact.agentTemplateId == nil
        case .agents:
            return contact.agentTemplateId != nil
        }
    }
}
