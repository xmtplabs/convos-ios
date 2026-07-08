import ConvosCore
import Foundation

extension Contact {
    /// Whether this contact renders in the Contacts browse list - and thus
    /// counts toward the App Settings "Contacts" badge, which must agree
    /// with the list. Shown: humans with a display name, verified
    /// template-backed agents, and verified agents that do not have a mirrored
    /// template yet. Hidden: unverified agents and unnamed humans (they'd
    /// render as "Somebody" with nothing to distinguish them). All agents stay
    /// in `DBContact` so chat-side surfaces can still resolve them.
    ///
    /// Agents must be verified to appear; a template id is optional. Template-
    /// backed agents still collapse to one canonical row per template
    /// (`dedupingAgentsByTemplate`). Template-less verified agents are keyed by
    /// inbox id and behave like direct contacts: selecting them adds that
    /// already-running agent inbox rather than spawning a fresh template
    /// instance.
    var isVisibleInContactsList: Bool {
        if isAgent {
            return isVerifiedAgent
        }
        guard let displayName, !displayName.isEmpty else { return false }
        return true
    }
}
