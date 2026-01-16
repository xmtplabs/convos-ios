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
        let expiresAtUnix = Int64(date.timeIntervalSince1970)
        var metadata = try currentCustomMetadata
        metadata.expiresAtUnix = expiresAtUnix
        try await updateMetadata(metadata)
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
        if let existingKey = try imageEncryptionKey {
            return existingKey
        }

        let newKey = try ImageEncryption.generateGroupKey()
        try await atomicUpdateMetadata { metadata in
            if !metadata.hasImageEncryptionKey {
                metadata.imageEncryptionKey = newKey
            }
        } verify: { metadata in
            metadata.hasImageEncryptionKey
        }

        guard let finalKey = try imageEncryptionKey else {
            throw ImageEncryptionError.keyGenerationFailed
        }
        return finalKey
    }

    public var encryptedGroupImage: EncryptedImageRef? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasEncryptedGroupImage,
                  metadata.encryptedGroupImage.isValid else {
                return nil
            }
            return metadata.encryptedGroupImage
        }
    }

    public func updateEncryptedGroupImage(_ encryptedRef: EncryptedImageRef) async throws {
        try await atomicUpdateMetadata { metadata in
            metadata.encryptedGroupImage = encryptedRef
        } verify: { metadata in
            metadata.hasEncryptedGroupImage &&
            metadata.encryptedGroupImage.url == encryptedRef.url &&
            metadata.encryptedGroupImage.salt == encryptedRef.salt &&
            metadata.encryptedGroupImage.nonce == encryptedRef.nonce
        }
    }

    // This should only be done by the conversation creator
    // Updating the invite tag effectively expires all invites generated with that tag
    // The tag is used by the invitee to verify the conversation they've been added to
    // is the one that corresponds to the invite they are requesting to join
    public func ensureInviteTag() async throws {
        let existingTag = try inviteTag
        guard existingTag.isEmpty else { return }

        let newTag = try generateSecureRandomString(length: 10)
        try await atomicUpdateMetadata { metadata in
            if metadata.tag.isEmpty {
                metadata.tag = newTag
            }
        } verify: { metadata in
            !metadata.tag.isEmpty
        }
    }

    /// Rotates the invite tag, invalidating all existing invites for this conversation.
    /// This is used when locking a conversation to ensure no outstanding invites can be used.
    public func rotateInviteTag() async throws {
        var customMetadata = try currentCustomMetadata
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

                if profile.hasEncryptedImage, profile.encryptedImage.isValid {
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
        var metadata = try currentCustomMetadata
        metadata.upsertProfile(conversationProfile)
        try await updateMetadata(metadata)
    }

    /// Performs an optimistic concurrency update on group metadata with verification.
    ///
    /// This uses a read-modify-write pattern with post-write verification:
    /// 1. Read current metadata
    /// 2. Apply modifications
    /// 3. Write to XMTP
    /// 4. Re-read and verify the change persisted
    /// 5. Retry with exponential backoff if verification fails
    ///
    /// **Concurrency Model:**
    /// - Not truly atomic - concurrent writes can overwrite each other
    /// - Verification catches most conflicts (verification fails → retry)
    /// - Callers should include idempotency checks in `modify` closure
    ///   (e.g., `if !metadata.hasKey { metadata.key = newKey }`)
    /// - Suitable for infrequent, user-initiated operations
    ///
    /// - Parameters:
    ///   - maxRetries: Maximum retry attempts (default: 3)
    ///   - modify: Closure to modify the metadata
    ///   - verify: Closure to verify the modification persisted
    /// - Throws: `ConversationCustomMetadataError.metadataUpdateFailed` if all retries exhausted
    private func atomicUpdateMetadata(
        maxRetries: Int = 3,
        modify: (inout ConversationCustomMetadata) -> Void,
        verify: (ConversationCustomMetadata) -> Bool
    ) async throws {
        for attempt in 0..<maxRetries {
            var metadata = try currentCustomMetadata
            modify(&metadata)
            try await updateMetadata(metadata)

            let finalMetadata = try currentCustomMetadata
            if verify(finalMetadata) {
                return
            }

            if attempt < maxRetries - 1 {
                let delayMs = UInt64(50_000_000 * (attempt + 1))
                try await Task.sleep(nanoseconds: delayMs)
                Log.warning("Metadata update verification failed, retrying (attempt \(attempt + 1)/\(maxRetries))")
            }
        }
        throw ConversationCustomMetadataError.metadataUpdateFailed
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
