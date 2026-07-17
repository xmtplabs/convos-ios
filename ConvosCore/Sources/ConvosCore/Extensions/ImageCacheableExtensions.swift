import Foundation

extension Profile: ImageCacheable {
    /// User-scoped cache key. The avatar is logically one image per user
    /// even though each conversation stores its own encrypted copy
    /// (separate `imageEncryptionKey`, salt, nonce, URL per conversation —
    /// because we have no centralized profile-photo store yet). Keying by
    /// `inboxId` lets a successful fetch in any conversation satisfy
    /// every other conversation's render of the same user, and collapses
    /// what was previously N per-conversation cache entries into one.
    /// Display name and metadata are still per-conversation; only the
    /// avatar bytes are shared.
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

extension LinkPreview: ImageCacheable {
    public var imageCacheIdentifier: String {
        url
    }

    public var imageCacheURL: URL? {
        imageURL.flatMap { URL(string: $0) }
    }
}

extension Conversation: ImageCacheable {
    public var imageCacheIdentifier: String {
        switch avatarType {
        case .customImage:
            return clientConversationId
        case .profile(let profile, _):
            return profile.imageCacheIdentifier
        default:
            return clientConversationId
        }
    }

    public var imageCacheURL: URL? {
        switch avatarType {
        case .customImage:
            return imageURL
        case .profile(let profile, _):
            return profile.avatarURL
        default:
            return nil
        }
    }

    public var isEncryptedImage: Bool {
        switch avatarType {
        case .customImage:
            return true
        case .profile(let profile, _):
            return profile.isAvatarEncrypted
        default:
            return false
        }
    }

    public var encryptionSalt: Data? {
        switch avatarType {
        case .customImage:
            return imageSalt
        case .profile(let profile, _):
            return profile.avatarSalt
        default:
            return nil
        }
    }

    public var encryptionNonce: Data? {
        switch avatarType {
        case .customImage:
            return imageNonce
        case .profile(let profile, _):
            return profile.avatarNonce
        default:
            return nil
        }
    }

    public var encryptionKey: Data? {
        switch avatarType {
        case .customImage:
            return imageEncryptionKey
        case .profile(let profile, _):
            return profile.avatarKey
        default:
            return nil
        }
    }
}
