import Foundation

extension Profile: ImageCacheable {
    public var imageCacheIdentifier: String {
        inboxId
    }
}

extension MessageInvite: ImageCacheable {
    public var imageCacheIdentifier: String {
        inviteSlug
    }
}

extension Conversation: ImageCacheable {
    public var imageCacheIdentifier: String {
        clientConversationId
    }
}
