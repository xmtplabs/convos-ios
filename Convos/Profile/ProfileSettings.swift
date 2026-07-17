import ConvosCore
import Foundation
import UIKit

struct ProfileSettings: Equatable {
    let displayName: String
    let profileImage: UIImage?

    static var defaultSettings: Self {
        ProfileSettings(displayName: "", profileImage: nil)
    }

    var isDefault: Bool {
        self == Self.defaultSettings
    }

    var profile: Profile {
        profile()
    }

    func profile(inboxId: String = "", conversationId: String = Self.previewConversationId) -> Profile {
        .init(
            inboxId: inboxId,
            conversationId: conversationId,
            name: displayName.isEmpty ? nil : displayName,
            avatar: nil
        )
    }

    func with(displayName: String) -> Self {
        .init(displayName: displayName, profileImage: profileImage)
    }

    func with(profileImage: UIImage?) -> Self {
        .init(displayName: displayName, profileImage: profileImage)
    }

    private static let previewConversationId: String = "profile-preview"
}
