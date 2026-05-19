import ConvosCore
import Foundation

extension Contact {
    /// Resolves the subtitle rendered below the display name in shared
    /// contact-list rows (`ContactRowView`, `ContactsPickerRow`). Reads:
    ///
    /// 1. Source-conversation name when available (the convo the user met
    ///    them in, e.g. "Bike Trip 2026").
    /// 2. `"DM"` when the source is a 1:1 (no group name to show).
    /// 3. Agent role label for verified agents.
    /// 4. Empty string — caller hides the line entirely (unnamed group,
    ///    deleted source convo, synthetic contact, etc.).
    ///
    /// Pulled out of the picker view model so the contacts browser can
    /// share the same priority order without duplicating it.
    func listSubtitle(sources: [String: ContactSourceConversation]) -> String {
        if let viaId = addedViaConversationId, let source = sources[viaId] {
            if let name = source.name {
                return name
            }
            if source.kind == .dm {
                return "DM"
            }
        }
        if let roleLabel = agentVerification?.roleLabel {
            return roleLabel
        }
        return ""
    }
}
