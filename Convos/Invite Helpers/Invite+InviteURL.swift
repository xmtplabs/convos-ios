import ConvosCore
import Foundation

extension Invite {
    var inviteURLString: String {
        "https://\(ConfigManager.shared.associatedDomain)/v2?i=\(urlSlug)"
    }
    var inviteURL: URL? {
        return URL(string: inviteURLString)
    }
}
