import Foundation

extension DBMemberProfile {
    func hydrateProfile() -> Profile {
        Profile(
            inboxId: inboxId,
            conversationId: conversationId,
            name: name,
            avatar: avatar,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce
        )
    }
}
