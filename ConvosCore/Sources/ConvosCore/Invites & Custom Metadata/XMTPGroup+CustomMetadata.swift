import Foundation
import SwiftProtobuf
import XMTPiOS

// swiftlint:disable:next orphaned_doc_comment
/// XMTP groups expose an 8 KB `appData` field that Convos uses to store structured
/// metadata as a compressed, base64-encoded protobuf. This metadata includes:
/// - Invite tag: Unique identifier linking invites to conversations
/// - Description: User-visible conversation description
/// - Expiration date: Unix timestamp for when conversation auto-deletes
/// - Member profiles: Name and avatar for each member (per-conversation identities)
///
/// **Encoding Optimizations:**
/// - Binary fields (inbox IDs) stored as raw bytes instead of hex strings
/// - Unix timestamps (sfixed64) instead of protobuf Timestamp messages
/// - DEFLATE compression for payloads >100 bytes (typically 20-40% reduction)
/// - Overall 40-60% size reduction for multi-member groups
///
/// This allows Convos to store rich conversation metadata without requiring a backend.

// MARK: - XMTPiOS.Group + CustomMetadata

extension XMTPiOS.Group {
    private static let appDataByteLimit: Int = 8 * 1024

    var currentCustomMetadata: ConversationCustomMetadata {
        get throws {
            do {
                let currentAppData = try self.appData()
                return ConversationCustomMetadata.parseAppData(currentAppData)
            } catch XMTPiOS.GenericError.GroupError(message: _) {
                return .init()
            }
        }
    }

    public var inviteTag: String {
        get throws {
            try currentCustomMetadata.tag
        }
    }

    public var expiresAt: Date? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasExpiresAtUnix else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(metadata.expiresAtUnix))
        }
    }

    public func updateExpiresAt(date: Date) async throws {
        var customMetadata = try currentCustomMetadata
        customMetadata.expiresAtUnix = Int64(date.timeIntervalSince1970)
        try await updateMetadata(customMetadata)
    }

    // MARK: - Image Encryption Key Management

    public var imageEncryptionKey: Data? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasImageEncryptionKey else { return nil }
            return metadata.imageEncryptionKey
        }
    }

    @discardableResult
    public func ensureImageEncryptionKey() async throws -> Data {
        let initialMetadata = try currentCustomMetadata
        if initialMetadata.hasImageEncryptionKey {
            return initialMetadata.imageEncryptionKey
        }

        let newKey = try ImageEncryption.generateGroupKey()
        var updatedMetadata = initialMetadata
        updatedMetadata.imageEncryptionKey = newKey
        try await updateMetadata(updatedMetadata)

        let finalMetadata = try currentCustomMetadata
        guard finalMetadata.hasImageEncryptionKey else {
            throw ImageEncryptionError.keyGenerationFailed
        }
        return finalMetadata.imageEncryptionKey
    }

    public var encryptedGroupImage: EncryptedImageRef? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasEncryptedGroupImage else { return nil }
            return metadata.encryptedGroupImage
        }
    }

    public func updateEncryptedGroupImage(_ encryptedRef: EncryptedImageRef) async throws {
        var customMetadata = try currentCustomMetadata
        customMetadata.encryptedGroupImage = encryptedRef
        try await updateMetadata(customMetadata)
    }

    // This should only be done by the conversation creator
    // Updating the invite tag effectively expires all invites generated with that tag
    // The tag is used by the invitee to verify the conversation they've been added to
    // is the one that corresponds to the invite they are requesting to join
    public func ensureInviteTag() async throws {
        var customMetadata = try currentCustomMetadata
        guard customMetadata.tag.isEmpty else { return }
        customMetadata.tag = try generateSecureRandomString(length: 10)
        try await updateMetadata(customMetadata)
    }

    /// Generates a cryptographically secure random string of specified length
    /// using alphanumeric characters (a-z, A-Z, 0-9)
    private func generateSecureRandomString(length: Int) throws -> String {
        // Validate that length is positive
        guard length > 0 else {
            throw ConversationCustomMetadataError.invalidLength(length)
        }

        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let charactersArray = Array(characters)
        let charactersCount = charactersArray.count

        var randomBytes = [UInt8](repeating: 0, count: length)
        let result = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes)

        guard result == errSecSuccess else {
            throw ConversationCustomMetadataError.randomGenerationFailed
        }

        let randomString = randomBytes.map { byte in
            // Use modulo to map random byte to character index
            // This gives a slight bias but is acceptable for non-cryptographic identifiers
            let index = Int(byte) % charactersCount
            return charactersArray[index]
        }

        return String(randomString)
    }

    var memberProfiles: [DBMemberProfile] {
        get throws {
            let customMetadata = try currentCustomMetadata
            return customMetadata.profiles.map { profile in
                let avatarUrl: String?
                let salt: Data?
                let nonce: Data?

                if profile.hasEncryptedImage {
                    avatarUrl = profile.encryptedImage.url
                    salt = profile.encryptedImage.salt
                    nonce = profile.encryptedImage.nonce
                } else {
                    avatarUrl = profile.hasImage ? profile.image : nil
                    salt = nil
                    nonce = nil
                }

                return .init(
                    conversationId: id,
                    inboxId: profile.inboxIdString,
                    name: profile.hasName ? profile.name : nil,
                    avatar: avatarUrl,
                    avatarSalt: salt,
                    avatarNonce: nonce
                )
            }
        }
    }

    func updateProfile(_ profile: DBMemberProfile) async throws {
        guard let conversationProfile = profile.conversationProfile else {
            throw ConversationCustomMetadataError.invalidInboxIdHex(profile.inboxId)
        }
        var customMetadata = try currentCustomMetadata
        customMetadata.upsertProfile(conversationProfile)
        try await updateMetadata(customMetadata)
    }

    func updateMetadata(_ metadata: ConversationCustomMetadata) async throws {
        let encodedMetadata = try metadata.toCompactString()
        let byteCount = encodedMetadata.lengthOfBytes(using: .utf8)
        guard byteCount <= Self.appDataByteLimit else {
            throw ConversationCustomMetadataError.appDataLimitExceeded(limit: Self.appDataByteLimit, actualSize: byteCount)
        }
        try await updateAppData(appData: encodedMetadata)
    }
}
