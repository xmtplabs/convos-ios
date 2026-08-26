import ConvosAppData
import Foundation
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


/// The mutation `XMTPGroup.updateAgentModel` performs, as a plain function so
/// it can be exercised without a group.
///
/// Authors the agent's profile when the room carries none, because profiles
/// travel as ProfileUpdate messages and appData holds one only for a member who
/// has published an avatar — so there is usually nothing to hang a model on.
func applyAgentModel(
    _ model: String?,
    to metadata: inout ConversationCustomMetadata,
    forAgent inboxId: String,
    name: String? = nil
) {
    let key = inboxId.lowercased()
    if let index = metadata.profiles.firstIndex(where: {
        $0.inboxIdString.lowercased() == key
    }) {
        if let model {
            metadata.profiles[index].model = model
        } else {
            metadata.profiles[index].clearModel()
        }
        return
    }
    // Nothing to author for a clear: with no profile there is no model recorded
    // to take back.
    guard let model, let inboxIdData = Data(hexString: key) else { return }
    var profile = ConversationProfile()
    profile.inboxID = inboxIdData
    if let name, !name.isEmpty { profile.name = name }
    profile.model = model
    metadata.profiles.append(profile)
}

/// Whether `metadata` already says what `applyAgentModel` was asked to write.
func agentModelMatches(
    _ model: String?,
    in metadata: ConversationCustomMetadata,
    forAgent inboxId: String
) -> Bool {
    let key = inboxId.lowercased()
    let profile = metadata.profiles.first { $0.inboxIdString.lowercased() == key }
    if let model {
        return profile?.model == model
    }
    // A cleared model and a profile that was never authored both read as the
    // agent carrying no model, which is the state asked for.
    return profile?.hasModel != true
}

extension XMTPiOS.Group {
    private static let appDataByteLimit: Int = 8 * 1024

    var currentCustomMetadata: ConversationCustomMetadata {
        get throws {
            do {
                let currentAppData = try self.appData()
                return ConversationCustomMetadata.parseAppData(currentAppData)
            } catch {
                Log.error("Failed to read custom metadata: \(error)")
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

    public var conversationEmoji: String? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasEmoji, !metadata.emoji.isEmpty else { return nil }
            return metadata.emoji
        }
    }

    public func ensureConversationEmoji(seed: String) async throws -> String {
        if let existingEmoji = try conversationEmoji {
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

        return try conversationEmoji ?? generatedEmoji
    }

    public func updateExpiresAt(date: Date) async throws {
        let expiresAtUnix = Int64(date.timeIntervalSince1970)
        try await atomicUpdateMetadata(operation: "updateExpiresAt") { metadata in
            metadata.expiresAtUnix = expiresAtUnix
        } verify: { metadata in
            metadata.hasExpiresAtUnix && metadata.expiresAtUnix == expiresAtUnix
        }
    }

    /// The conversation's agent participation mode, or nil while no member has
    /// set one. Read from synced group state, so a member who just joined sees
    /// the mode the conversation is already in without asking a server.
    public var participationMode: ConversationParticipationMode? {
        get throws {
            try currentCustomMetadata.conversationParticipationMode
        }
    }

    /// Sets the mode for every agent in the conversation. Any member may call
    /// this - the mode is conversation state, not an owner-only setting - and
    /// MLS metadata's last-writer-wins resolution settles two members changing
    /// it at once.
    public func updateParticipationMode(_ mode: ConversationParticipationMode) async throws {
        try await atomicUpdateMetadata(operation: "updateParticipationMode") { metadata in
            metadata.participationMode = mode.proto
        } verify: { metadata in
            metadata.conversationParticipationMode == mode
        }
    }

    /// The model each agent in the conversation runs on, keyed by lowercase hex
    /// inbox id, for the agents that carry one.
    ///
    /// Read from synced group state, like the participation mode, so a member
    /// sees what every other member's agent was switched to without asking a
    /// server. Unlike the mode, this is per agent: a room holding several
    /// carries one entry each, and an agent nobody has switched carries none —
    /// it runs whatever its own template shipped, which only it can name.
    ///
    /// Written by the member who picks it, the way the participation mode is,
    /// so the commit carries that member's name into the transcript. The
    /// Assistant Worker still owns the value: it validates a choice against the
    /// agent's own catalogue and republishes here whenever the row moves on its
    /// side — a refused model, one dropped from the catalogue, or one chosen
    /// before the agent had a conversation to publish into.
    /// Nil means the appData said nothing about models, which is not the same as
    /// saying there are none. `currentCustomMetadata` turns an unreadable blob
    /// into empty metadata rather than throwing, so an empty profile list is
    /// indistinguishable from a failed read — and the models hang off those
    /// profiles, so with none present this carries no information either way.
    /// Callers must preserve what they already hold rather than clear it.
    public var agentModels: [String: String]? {
        get throws {
            let metadata = try currentCustomMetadata
            guard !metadata.profiles.isEmpty else { return nil }
            return metadata.profiles.reduce(into: [:]) { models, profile in
                guard profile.hasModel, !profile.model.isEmpty else { return }
                models[profile.inboxIdString.lowercased()] = profile.model
            }
        }
    }

    /// Sets the model one agent runs on, or clears it when nil, leaving every
    /// other agent's entry alone.
    ///
    /// Optimistic, and deliberately so. The member's pick is written here first
    /// and confirmed with the control plane after, which is what puts that
    /// member's name on the transcript row rather than the agent's — the
    /// Assistant Worker signs its own commits. If the runtime refuses the
    /// model, the Worker rolls its row back and republishes, so the room
    /// converges on what the agent actually runs.
    ///
    /// Authors a profile for the agent when the room carries none: profiles
    /// travel as ProfileUpdate messages and appData holds one only for a member
    /// who has published an avatar, so there is often nothing to hang a model
    /// on. `name` is carried in when known so the entry cannot present the
    /// agent as nameless to a client reading appData.
    public func updateAgentModel(
        _ model: String?,
        forAgent inboxId: String,
        name: String? = nil
    ) async throws {
        try await atomicUpdateMetadata(operation: "updateAgentModel") { metadata in
            applyAgentModel(model, to: &metadata, forAgent: inboxId, name: name)
        } verify: { metadata in
            agentModelMatches(model, in: metadata, forAgent: inboxId)
        }
    }

    /// Whether this conversation carries the agent-DM marker. The agent's
    /// identity comes from the membership itself (member kind plus
    /// attestation), not from the marker; callers gating UI should also
    /// require exactly 2 members with an agent as the other member.
    public var isAgentDm: Bool {
        get throws {
            try currentCustomMetadata.hasAgentDm
        }
    }

    /// The parent ("origin") conversation this agent DM was created from, as a
    /// hex conversation id, or nil when not recorded. Written once in
    /// `markAsAgentDm`; read back so a DM notification tap can route to its
    /// parent group (the DM is only viewable as a page inside that group), and
    /// so auto-allow can gate on the user still sharing that primary (the marker
    /// itself is member-writable appData).
    public var agentDmOriginConversationId: String? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasAgentDm, metadata.agentDm.hasOriginConversationID else {
                return nil
            }
            let data = metadata.agentDm.originConversationID
            return data.isEmpty ? nil : data.toHexString()
        }
    }

    /// The deployed Space web URL for this conversation, or nil while none has
    /// been published. The Assistant Worker writes it into appData and is the
    /// sole authority; clients never construct or write this value.
    public var spaceURL: String? {
        get throws {
            let metadata = try currentCustomMetadata
            guard metadata.hasSpaceURL, !metadata.spaceURL.isEmpty else { return nil }
            return metadata.spaceURL
        }
    }

    /// Overwrites the Space web URL in appData, or clears it when nil. The
    /// Assistant Worker is the value's authority (see `spaceURL`); this setter
    /// exists only for the debug override in conversation info, and the worker
    /// may replace whatever it writes on its next publish.
    public func updateSpaceURL(_ urlString: String?) async throws {
        try await atomicUpdateMetadata(operation: "updateSpaceURL") { metadata in
            if let urlString {
                metadata.spaceURL = urlString
            } else {
                metadata.clearSpaceURL()
            }
        } verify: { metadata in
            if let urlString {
                return metadata.spaceURL == urlString
            } else {
                return !metadata.hasSpaceURL
            }
        }
    }

    /// Stamps this conversation as a private DM with an agent. Called once by
    /// the device that creates the DM conversation, before adding the agent.
    public func markAsAgentDm(originConversationId: Data? = nil) async throws {
        try await atomicUpdateMetadata(operation: "markAsAgentDm") { metadata in
            var info = AgentDmInfo()
            if let originConversationId {
                info.originConversationID = originConversationId
            }
            metadata.agentDm = info
        } verify: { metadata in
            metadata.hasAgentDm
        }
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
        try await atomicUpdateMetadata(operation: "ensureImageEncryptionKey") { metadata in
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
        try await atomicUpdateMetadata(operation: "updateEncryptedGroupImage") { metadata in
            metadata.encryptedGroupImage = encryptedRef
        } verify: { metadata in
            metadata.hasEncryptedGroupImage &&
            metadata.encryptedGroupImage.url == encryptedRef.url &&
            metadata.encryptedGroupImage.salt == encryptedRef.salt &&
            metadata.encryptedGroupImage.nonce == encryptedRef.nonce
        }
    }

    /// Seeds every piece of creator-authored metadata in one commit: the
    /// invite tag, the image encryption key, (when a seed is provided) the
    /// conversation emoji, and the initial participation mode. Each individual
    /// `ensure*` call publishes its own MLS commit with a network round trip,
    /// so the creation path calls this instead of chaining them. No-ops without
    /// a commit when every field is already present.
    ///
    /// The participation mode is seeded to Listen (`.mentionsOnly`) so a new
    /// conversation's agents stay quiet until addressed. This only reaches group
    /// chats: agent DMs are created by the agent, so their `creatorInboxId` is
    /// never this client and they never call this creator-only method. The seed
    /// is tied to authoring the invite tag -- the one field written exactly once,
    /// at creation -- so it never fires when this method re-runs on an already
    /// established group (e.g. `StreamProcessor` reprocessing a legacy
    /// creator-owned conversation), which would otherwise flip that room off the
    /// legacy default and publish a spurious commit.
    ///
    /// Only the conversation creator should call this - it authors the
    /// invite tag (see `ensureInviteTag`).
    public func ensureCreatorMetadata(emojiSeed: String? = nil) async throws {
        let current = try currentCustomMetadata
        let needsTag = current.tag.isEmpty
        let needsKey = !current.hasImageEncryptionKey
        let needsEmoji = emojiSeed != nil && (!current.hasEmoji || current.emoji.isEmpty)
        // Only seed the initial mode in the same commit that first authors the
        // invite tag, i.e. a brand-new group. An established group (tag already
        // present) that happens to carry no mode must keep rendering as the
        // legacy default, untouched.
        let seedsParticipationMode = needsTag && current.conversationParticipationMode == nil
        guard needsTag || needsKey || needsEmoji else { return }

        // Generate the tag only when it's actually missing so a transient
        // SecRandomCopyBytes failure can't abort an emoji- or key-only update.
        let newTag: String? = needsTag ? try generateSecureRandomString(length: 10) : nil
        // Key generation failure stays non-fatal, matching how callers treat
        // `ensureImageEncryptionKey`: the key is retried on first image
        // upload, while a missing invite tag breaks joins.
        var newKey: Data?
        if needsKey {
            do {
                newKey = try ImageEncryption.generateGroupKey()
            } catch {
                Log.warning("Failed to generate image encryption key: \(error). Will retry on first image upload.")
            }
        }
        let newEmoji: String? = emojiSeed.map { EmojiSelector.emoji(for: $0) }

        try await atomicUpdateMetadata(operation: "ensureCreatorMetadata") { metadata in
            if let newTag, metadata.tag.isEmpty {
                metadata.tag = newTag
            }
            if let newKey, !metadata.hasImageEncryptionKey {
                metadata.imageEncryptionKey = newKey
            }
            if let newEmoji, !metadata.hasEmoji || metadata.emoji.isEmpty {
                metadata.emoji = newEmoji
            }
            if seedsParticipationMode, metadata.conversationParticipationMode == nil {
                metadata.participationMode = ConversationParticipationMode.mentionsOnly.proto
            }
        } verify: { metadata in
            guard !metadata.tag.isEmpty else { return false }
            guard newKey == nil || metadata.hasImageEncryptionKey else { return false }
            guard newEmoji == nil || (metadata.hasEmoji && !metadata.emoji.isEmpty) else { return false }
            return !seedsParticipationMode || metadata.conversationParticipationMode != nil
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
    public func rotateInviteTag() async throws {
        let oldTag = try inviteTag
        let newTag = try generateSecureRandomString(length: 10)
        try await atomicUpdateMetadata(operation: "rotateInviteTag") { metadata in
            metadata.tag = newTag
        } verify: { metadata in
            metadata.tag != oldTag && !metadata.tag.isEmpty
        }
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
            try memberProfiles(withKey: imageEncryptionKey)
        }
    }

    func memberProfiles(withKey groupKey: Data?) throws -> [DBMemberProfile] {
        let customMetadata = try currentCustomMetadata
        return customMetadata.profiles.map { profile in
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

    func updateProfile(_ profile: DBMemberProfile) async throws {
        guard let conversationProfile = profile.conversationProfile else {
            throw ConversationCustomMetadataError.invalidInboxIdHex(profile.inboxId)
        }
        // Merge instead of replacing wholesale: a profile built from
        // incomplete local state (fresh pairing, mid-hydration) must not drop
        // avatar or connections fields that already exist in the metadata.
        // The verify closure checks the merged invariant - exact equality
        // would reject every preserved field and burn the retries.
        try await atomicUpdateMetadata(operation: "updateProfile") { metadata in
            metadata.mergeProfile(conversationProfile)
        } verify: { metadata in
            // Verify only the fields this write actually sets: name and image.
            // connections is deliberately excluded - it lives only in remote
            // metadata and is never carried by a profile built from a local
            // DBMemberProfile, so the merge preserves it untouched. Asserting
            // on it here would verify a field this operation doesn't author and
            // could fail (and burn retries) whenever connections legitimately
            // differ from this device's empty view of them.
            guard let final = metadata.findProfile(inboxId: profile.inboxId) else { return false }
            let incomingName: String? = conversationProfile.hasName ? conversationProfile.name : nil
            let finalName: String? = final.hasName ? final.name : nil
            guard finalName == incomingName else { return false }
            guard let incomingImageUrl = conversationProfile.effectiveImageUrl else { return true }
            return final.effectiveImageUrl == incomingImageUrl
        }
    }

    /// Explicitly removes the avatar fields from a member's profile entry.
    /// `updateProfile` deliberately preserves existing image fields when the
    /// incoming profile carries none, so removal has to be a named operation
    /// rather than a side effect of writing an avatar-less profile.
    func clearProfileAvatar(inboxId: String) async throws {
        try await atomicUpdateMetadata(operation: "clearProfileAvatar") { metadata in
            guard var profile = metadata.findProfile(inboxId: inboxId) else { return }
            profile.clearEncryptedImage()
            profile.clearImage()
            metadata.upsertProfile(profile)
        } verify: { metadata in
            let profile = metadata.findProfile(inboxId: inboxId)
            return profile == nil || profile?.effectiveImageUrl == nil
        }
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
    public func restoreInviteTagIfMissing(_ expectedTag: String) async throws {
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

    private static func isValidInviteTag(_ tag: String) -> Bool {
        tag.range(of: "^[A-Za-z0-9]{10}$", options: .regularExpression) != nil
    }

    private func atomicUpdateMetadata(
        operation: String,
        maxRetries: Int = 3,
        modify: (inout ConversationCustomMetadata) -> Void,
        verify: (ConversationCustomMetadata) -> Bool
    ) async throws {
        for attempt in 0..<maxRetries {
            let beforeAppData = try appData()
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

            let finalAppData = try appData()
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

    func updateMetadata(_ metadata: ConversationCustomMetadata) async throws {
        if let currentTag = try? inviteTag,
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
        try await updateAppData(appData: encodedMetadata)
    }
}
