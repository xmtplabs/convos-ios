import ConvosCore
import Foundation

extension Contact {
    /// Whether this contact renders in the Contacts browse list - and thus
    /// counts toward the App Settings "Contacts" badge, which must agree
    /// with the list. Shown: humans with a display name, and template-backed
    /// agents (tagged with the Agent pill). Hidden: legacy verified
    /// assistants without a template, agents whose template metadata hasn't
    /// mirrored yet, and unnamed humans (they'd render as "Somebody" with
    /// nothing to distinguish them). All agents stay in `DBContact` so
    /// chat-side surfaces can still resolve them.
    var isVisibleInContactsList: Bool {
        if agentVerification != nil {
            return agentTemplateId != nil
        }
        guard let displayName, !displayName.isEmpty else { return false }
        return true
    }
}
