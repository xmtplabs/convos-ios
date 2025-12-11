import Foundation

extension DBMemberProfile {
    func hydrateProfile() -> Profile {
        Profile(
            inboxId: inboxId,
            name: name,
            avatar: avatar
        )
    }
}
