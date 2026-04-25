import ConvosAppData
import ConvosMessagingProtocols
import ConvosProfiles
import Foundation

// swiftlint:disable:next orphaned_doc_comment
/// Convos custom-metadata engine, migrated to operate on the `MessagingGroup`
/// abstraction instead of `XMTPiOS.Group`. XMTP groups expose an 8 KB
/// `appData` field that Convos uses to store structured metadata as a
/// compressed, base64-encoded protobuf. This metadata includes:
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
///
/// The logic here is intentionally pure-abstraction: it only uses
/// `MessagingGroup.id`, `appData()`, and `updateAppData(_:)`. The thin
/// `XMTPGroup+CustomMetadata.swift` shim re-exposes the same surface on the
/// raw `XMTPiOS.Group` type by delegating into `ConversationCustomMetadataEngine`.

// MARK: - Engine

/// Underlying reader/writer engine for Convos custom-metadata operations.
///
/// The engine is parameterised over closures that read / write the 8 KB
/// `appData` protobuf blob and expose the hosting conversation's id. This
/// lets the same optimistic-concurrency update logic power both the
/// `MessagingGroup` extension (abstraction-side) and the
/// `XMTPGroup+CustomMetadata.swift` boundary shim (raw `XMTPiOS.Group`).
struct ConversationCustomMetadataEngine {
    static let appDataByteLimit: Int = 8 * 1024

    let id: String
    let readAppData: () async throws -> String
    let writeAppData: (String) async throws -> Void

    // MARK: - Reads

    func currentCustomMetadata() async throws -> ConversationCustomMetadata {
        do {
            let raw = try await readAppData()
            return ConversationCustomMetadata.parseAppData(raw)
        } catch {
            Log.error("Failed to read custom metadata: \(error)")
            return .init()
        }
    }

    func inviteTag() async throws -> String {
        try await currentCustomMetadata().tag
    }

    func expiresAt() async throws -> Date? {
        let metadata = try await currentCustomMetadata()
        guard metadata.hasExpiresAtUnix else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(metadata.expiresAtUnix))
    }

    func conversationEmoji() async throws -> String? {
        let metadata = try await currentCustomMetadata()
        guard metadata.hasEmoji, !metadata.emoji.isEmpty else { return nil }
        return metadata.emoji
    }

    func imageEncryptionKey() async throws -> Data? {
        let metadata = try await currentCustomMetadata()
        guard metadata.hasImageEncryptionKey else { return nil }
        return metadata.imageEncryptionKey
    }

    func encryptedGroupImage() async throws -> EncryptedImageRef? {
        let metadata = try await currentCustomMetadata()
        guard metadata.hasEncryptedGroupImage,
              metadata.encryptedGroupImage.isValid else {
            return nil
        }
        return metadata.encryptedGroupImage
    }

    func memberProfiles(withKey groupKey: Data?) async throws -> [DBMemberProfile] {
        let metadata = try await currentCustomMetadata()
        return metadata.profiles.map { profile in
            let avatarUrl: String?
            let salt: Data?
            let nonce: Data?
            let key: Data?

            if profile.hasEncryptedImage, profile.encryptedImage.isValid {
                avatarUrl = profile.encryptedImage.url
                salt = profile.encryptedImage.salt
                nonce = profile.encryptedImage.nonce
                key = groupKey
            } else {
                avatarUrl = profile.hasImage ? profile.image : nil
                salt = nil
                nonce = nil
                key = nil
            }

            return .init(
                conversationId: id,
                inboxId: profile.inboxIdString,
                name: profile.hasName ? profile.name : nil,
                avatar: avatarUrl,
                avatarSalt: salt,
                avatarNonce: nonce,
                avatarKey: key
            )
        }
    }

    // MARK: - Writes

    func ensureConversationEmoji(seed: String) async throws -> String {
        if let existingEmoji = try await conversationEmoji() {
            return existingEmoji
        }

        let generatedEmoji = EmojiSelector.emoji(for: seed)
        try await atomicUpdateMetadata(operation: "ensureConversationEmoji") { metadata in
            if !metadata.hasEmoji || metadata.emoji.isEmpty {
                metadata.emoji = generatedEmoji
            }
        } verify: { metadata in
            metadata.hasEmoji && !metadata.emoji.isEmpty
        }

        return try await conversationEmoji() ?? generatedEmoji
    }

    func updateExpiresAt(date: Date) async throws {
        let expiresAtUnix = Int64(date.timeIntervalSince1970)
        try await atomicUpdateMetadata(operation: "updateExpiresAt") { metadata in
            metadata.expiresAtUnix = expiresAtUnix
        } verify: { metadata in
            metadata.hasExpiresAtUnix && metadata.expiresAtUnix == expiresAtUnix
        }
    }

    @discardableResult
    func ensureImageEncryptionKey() async throws -> Data {
        if let existingKey = try await imageEncryptionKey() {
            return existingKey
        }

        let newKey = try ImageEncryption.generateGroupKey()
        try await atomicUpdateMetadata(operation: "ensureImageEncryptionKey") { metadata in
            if !metadata.hasImageEncryptionKey {
                metadata.imageEncryptionKey = newKey
            }
        } verify: { metadata in
            metadata.hasImageEncryptionKey
        }

        guard let finalKey = try await imageEncryptionKey() else {
            throw ImageEncryptionError.keyGenerationFailed
        }
        return finalKey
    }

    func updateEncryptedGroupImage(_ encryptedRef: EncryptedImageRef) async throws {
        try await atomicUpdateMetadata(operation: "updateEncryptedGroupImage") { metadata in
            metadata.encryptedGroupImage = encryptedRef
        } verify: { metadata in
            metadata.hasEncryptedGroupImage &&
            metadata.encryptedGroupImage.url == encryptedRef.url &&
            metadata.encryptedGroupImage.salt == encryptedRef.salt &&
            metadata.encryptedGroupImage.nonce == encryptedRef.nonce
        }
    }

    func ensureInviteTag() async throws {
        let existingTag = try await inviteTag()
        guard existingTag.isEmpty else { return }

        let newTag = try Self.generateSecureRandomString(length: 10)
        try await atomicUpdateMetadata(operation: "ensureInviteTag") { metadata in
            if metadata.tag.isEmpty {
                metadata.tag = newTag
            }
        } verify: { metadata in
            !metadata.tag.isEmpty
        }
    }

    /// Rotates the invite tag, invalidating all existing invites for this conversation.
    /// This is used when locking a conversation to ensure no outstanding invites can be used.
    func rotateInviteTag() async throws {
        let oldTag = try await inviteTag()
        let newTag = try Self.generateSecureRandomString(length: 10)
        try await atomicUpdateMetadata(operation: "rotateInviteTag") { metadata in
            metadata.tag = newTag
        } verify: { metadata in
            metadata.tag != oldTag && !metadata.tag.isEmpty
        }
    }

    func restoreInviteTagIfMissing(_ expectedTag: String) async throws {
        guard !expectedTag.isEmpty else { return }
        guard Self.isValidInviteTag(expectedTag) else {
            throw ConversationCustomMetadataError.invalidInviteTag(expectedTag)
        }
        try await atomicUpdateMetadata(operation: "restoreInviteTagIfMissing") { metadata in
            guard metadata.tag.isEmpty else { return }
            metadata.tag = expectedTag
        } verify: { metadata in
            !metadata.tag.isEmpty
        }
    }

    func updateProfile(_ profile: DBMemberProfile) async throws {
        guard let conversationProfile = profile.conversationProfile else {
            throw ConversationCustomMetadataError.invalidInboxIdHex(profile.inboxId)
        }
        try await atomicUpdateMetadata(operation: "updateProfile") { metadata in
            metadata.upsertProfile(conversationProfile)
        } verify: { metadata in
            metadata.findProfile(inboxId: profile.inboxId) == conversationProfile
        }
    }

    func updateMetadata(_ metadata: ConversationCustomMetadata) async throws {
        if let currentTag = try? await inviteTag(),
           !currentTag.isEmpty,
           metadata.tag.isEmpty {
            Log.error("[MetadataDebug] updateMetadata refusing to clear invite tag for groupId=\(id)")
            throw ConversationCustomMetadataError.metadataUpdateFailed
        }

        let encodedMetadata = try metadata.toCompactString()
        let byteCount = encodedMetadata.lengthOfBytes(using: .utf8)
        guard byteCount <= Self.appDataByteLimit else {
            throw ConversationCustomMetadataError.appDataLimitExceeded(limit: Self.appDataByteLimit, actualSize: byteCount)
        }
        try await writeAppData(encodedMetadata)
    }

    // MARK: - Optimistic concurrency

    /// Performs an optimistic concurrency update on group metadata with verification.
    ///
    /// This uses a read-modify-write pattern with post-write verification:
    /// 1. Read current metadata
    /// 2. Apply modifications
    /// 3. Write to the backing store (XMTP `appData`)
    /// 4. Re-read and verify the change persisted
    /// 5. Retry with exponential backoff if verification fails
    ///
    /// **Concurrency Model:**
    /// - Not truly atomic - concurrent writes can overwrite each other
    /// - Verification catches most conflicts (verification fails → retry)
    /// - Callers should include idempotency checks in `modify` closure
    ///   (e.g., `if !metadata.hasKey { metadata.key = newKey }`)
    /// - Suitable for infrequent, user-initiated operations
    func atomicUpdateMetadata(
        operation: String,
        maxRetries: Int = 3,
        modify: (inout ConversationCustomMetadata) -> Void,
        verify: (ConversationCustomMetadata) -> Bool
    ) async throws {
        for attempt in 0..<maxRetries {
            let beforeAppData = try await readAppData()
            let beforeMetadata = ConversationCustomMetadata.parseAppData(beforeAppData)
            var metadata = beforeMetadata
            modify(&metadata)

            Log.info(
                "[MetadataDebug] operation=\(operation) groupId=\(id) attempt=\(attempt + 1) beforeTag=\(beforeMetadata.tag) afterTag=\(metadata.tag) beforeBytes=\(beforeAppData.utf8.count)"
            )
            if !beforeMetadata.tag.isEmpty && metadata.tag.isEmpty {
                Log.error("[MetadataDebug] operation=\(operation) cleared invite tag for groupId=\(id)")
                throw ConversationCustomMetadataError.metadataUpdateFailed
            }

            try await updateMetadata(metadata)

            let finalAppData = try await readAppData()
            let finalMetadata = ConversationCustomMetadata.parseAppData(finalAppData)
            Log.info(
                "[MetadataDebug] operation=\(operation) groupId=\(id) finalTag=\(finalMetadata.tag) finalBytes=\(finalAppData.utf8.count)"
            )
            if verify(finalMetadata) {
                return
            }

            if attempt < maxRetries - 1 {
                let delayMs = UInt64(50_000_000 * (attempt + 1))
                try await Task.sleep(nanoseconds: delayMs)
                Log.warning("Metadata update verification failed, retrying (operation=\(operation), attempt \(attempt + 1)/\(maxRetries))")
            }
        }
        throw ConversationCustomMetadataError.metadataUpdateFailed
    }

    // MARK: - Helpers

    static func isValidInviteTag(_ tag: String) -> Bool {
        tag.range(of: "^[A-Za-z0-9]{10}$", options: .regularExpression) != nil
    }

    /// Generates a cryptographically secure random string of specified length
    /// using alphanumeric characters (a-z, A-Z, 0-9)
    static func generateSecureRandomString(length: Int) throws -> String {
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
}

// MARK: - MessagingGroup + CustomMetadata

/// Convos custom-metadata API exposed on the abstraction. New call sites
/// should consume this surface via `any MessagingGroup`; legacy callers that
/// still hold onto raw `XMTPiOS.Group` use the shim in
/// `XMTPGroup+CustomMetadata.swift`, which delegates here.
extension MessagingGroup {
    var customMetadataEngine: ConversationCustomMetadataEngine {
        ConversationCustomMetadataEngine(
            id: id,
            readAppData: { [self] in try await self.appData() },
            writeAppData: { [self] newValue in try await self.updateAppData(newValue) }
        )
    }

    // MARK: Reads

    public func currentCustomMetadata() async throws -> ConversationCustomMetadata {
        try await customMetadataEngine.currentCustomMetadata()
    }

    public func inviteTag() async throws -> String {
        try await customMetadataEngine.inviteTag()
    }

    public func expiresAt() async throws -> Date? {
        try await customMetadataEngine.expiresAt()
    }

    public func conversationEmoji() async throws -> String? {
        try await customMetadataEngine.conversationEmoji()
    }

    public func imageEncryptionKey() async throws -> Data? {
        try await customMetadataEngine.imageEncryptionKey()
    }

    public func encryptedGroupImage() async throws -> EncryptedImageRef? {
        try await customMetadataEngine.encryptedGroupImage()
    }

    func memberProfiles() async throws -> [DBMemberProfile] {
        try await customMetadataEngine.memberProfiles(withKey: try? await imageEncryptionKey())
    }

    func memberProfiles(withKey groupKey: Data?) async throws -> [DBMemberProfile] {
        try await customMetadataEngine.memberProfiles(withKey: groupKey)
    }

    // MARK: Writes

    public func ensureConversationEmoji(seed: String) async throws -> String {
        try await customMetadataEngine.ensureConversationEmoji(seed: seed)
    }

    public func updateExpiresAt(date: Date) async throws {
        try await customMetadataEngine.updateExpiresAt(date: date)
    }

    @discardableResult
    public func ensureImageEncryptionKey() async throws -> Data {
        try await customMetadataEngine.ensureImageEncryptionKey()
    }

    public func updateEncryptedGroupImage(_ encryptedRef: EncryptedImageRef) async throws {
        try await customMetadataEngine.updateEncryptedGroupImage(encryptedRef)
    }

    /// Only the conversation creator should call this. Updating the invite
    /// tag effectively expires all invites generated with the previous tag.
    /// The tag is used by the invitee to verify the conversation they've been
    /// added to is the one that corresponds to the invite they are requesting
    /// to join.
    public func ensureInviteTag() async throws {
        try await customMetadataEngine.ensureInviteTag()
    }

    public func rotateInviteTag() async throws {
        try await customMetadataEngine.rotateInviteTag()
    }

    public func restoreInviteTagIfMissing(_ expectedTag: String) async throws {
        try await customMetadataEngine.restoreInviteTagIfMissing(expectedTag)
    }

    func updateProfile(_ profile: DBMemberProfile) async throws {
        try await customMetadataEngine.updateProfile(profile)
    }

    public func updateMetadata(_ metadata: ConversationCustomMetadata) async throws {
        try await customMetadataEngine.updateMetadata(metadata)
    }
}
