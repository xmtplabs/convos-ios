import Foundation

extension Profile: ImageCacheable {
    public var imageCacheIdentifier: String {
        inboxId
    }

    public var imageCacheURL: URL? {
        avatarURL
    }

    public var isEncryptedImage: Bool {
        isAvatarEncrypted
    }

    public var encryptionKey: Data? {
        avatarKey
    }

    public var encryptionSalt: Data? {
        avatarSalt
    }

    public var encryptionNonce: Data? {
        avatarNonce
    }
}

extension MessageInvite: ImageCacheable {
    public var imageCacheIdentifier: String {
        inviteSlug
    }

    public var imageCacheURL: URL? {
        imageURL
    }
}

extension Conversation: ImageCacheable {
    public var imageCacheIdentifier: String {
        switch avatarType {
        case .customImage:
            return clientConversationId
        case .profile(let profile):
            // Fall back to clientConversationId if inboxId is empty to prevent cache key collisions
            return profile.inboxId.isEmpty ? clientConversationId : profile.inboxId
        default:
            return clientConversationId
        }
    }

    public var imageCacheURL: URL? {
        switch avatarType {
        case .customImage:
            return imageURL
        case .profile(let profile):
            return profile.avatarURL
        default:
            return nil
        }
    }

    public var isEncryptedImage: Bool {
        switch avatarType {
        case .customImage:
            return true
        case .profile(let profile):
            return profile.isAvatarEncrypted
        default:
            return false
        }
    }

    public var encryptionSalt: Data? {
        switch avatarType {
        case .customImage:
            return imageSalt
        case .profile(let profile):
            return profile.avatarSalt
        default:
            return nil
        }
    }

    public var encryptionNonce: Data? {
        switch avatarType {
        case .customImage:
            return imageNonce
        case .profile(let profile):
            return profile.avatarNonce
        default:
            return nil
        }
    }

    public var encryptionKey: Data? {
        switch avatarType {
        case .customImage:
            return imageEncryptionKey
        case .profile(let profile):
            return profile.avatarKey
        default:
            return nil
        }
    }
}
