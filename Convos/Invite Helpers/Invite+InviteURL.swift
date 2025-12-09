import ConvosCore
import Foundation

extension Invite {
    var inviteURLString: String {
        // Use the primary associated domain (first in the list) for generating invite links
        "https://\(ConfigManager.shared.associatedDomains.first!)/v2?i=\(urlSlug)"
    }
    var inviteURL: URL? {
        return URL(string: inviteURLString)
    }
}
