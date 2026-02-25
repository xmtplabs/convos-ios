import ConvosAppData
import Foundation

// MARK: - DBMemberProfile + ConversationProfile

extension DBMemberProfile {
    var conversationProfile: ConversationProfile? {
        guard let encryptedRef = encryptedImageRef else {
            return ConversationProfile(inboxIdString: inboxId, name: name, imageUrl: avatar)
        }
        return ConversationProfile(inboxIdString: inboxId, name: name, encryptedImageRef: encryptedRef)
    }
}
