import ConvosCore
import Foundation

extension Contact {
    /// Whether this contact renders in the Contacts browse list - and thus
    /// counts toward the App Settings "Contacts" badge, which must agree
    /// with the list. Shown: humans with a display name, and verified,
    /// template-backed agents (tagged with the Agent pill). Hidden:
    /// unverified agents, verified agents whose template hasn't mirrored yet,
    /// and unnamed humans (they'd render as "Somebody" with nothing to
    /// distinguish them). All agents stay in `DBContact` so chat-side
    /// surfaces can still resolve them.
    ///
    /// An agent must be BOTH verified and template-backed to appear:
    /// - `isVerifiedAgent` (unforgeable attestation) - so a stale or spoofed
    ///   `templateId` on a non-verified contact never surfaces it, and only
    ///   real agents show.
    /// - `agentTemplateId != nil` - the contact list collapses agent
    ///   instances to one canonical row per template (`dedupingAgentsByTemplate`),
    ///   so an agent with no template has no canonical key and can't be shown.
    var isVisibleInContactsList: Bool {
        if isAgent {
            return isVerifiedAgent && agentTemplateId != nil
        }
        guard let displayName, !displayName.isEmpty else { return false }
        return true
    }
}
