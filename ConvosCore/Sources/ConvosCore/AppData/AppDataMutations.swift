import ConvosAppData
import Foundation
import Security

/// Invite-tag utilities shared by the enqueue-time change closures. Tags are
/// minted once at enqueue and frozen into the persisted snapshot; the merge
/// updater only ever transplants an already-minted value.
enum InviteTag {
    /// Generates a cryptographically secure random tag of alphanumeric
    /// characters (a-z, A-Z, 0-9).
    static func generate(length: Int = 10) throws -> String {
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
            // Modulo introduces a slight bias, acceptable for a
            // non-cryptographic identifier.
            let index = Int(byte) % charactersCount
            return charactersArray[index]
        }

        return String(randomString)
    }

    static func isValid(_ tag: String) -> Bool {
        tag.range(of: "^[A-Za-z0-9]{10}$", options: .regularExpression) != nil
    }
}

/// Named mutations used inside `enqueueChange` closures, extracted from the
/// retired per-operation group extensions so intent stays greppable. Each is
/// idempotent - re-running it against already-updated metadata is a no-op -
/// which is what makes the coordinator's re-merge verification sound.
extension ConversationCustomMetadata {
    /// Seeds the invite tag when missing. Ensure, and restore-if-missing,
    /// both reduce to this; rotation assigns `tag` unconditionally instead.
    mutating func ensureTag(_ tag: String) {
        guard self.tag.isEmpty else { return }
        self.tag = tag
    }

    /// Seeds the conversation emoji when missing.
    mutating func ensureEmoji(_ emoji: String) {
        guard !hasEmoji || self.emoji.isEmpty else { return }
        self.emoji = emoji
    }

    /// Stamps the agent-DM marker with an optional origin conversation id.
    mutating func markAgentDm(originConversationId: Data?) {
        var info = AgentDmInfo()
        if let originConversationId {
            info.originConversationID = originConversationId
        }
        agentDm = info
    }

    /// Explicitly removes the avatar fields from a member's profile entry.
    /// Profile merges deliberately preserve existing image fields when the
    /// incoming profile carries none, so removal has to be a named operation
    /// rather than a side effect of writing an avatar-less profile.
    mutating func clearProfileAvatar(inboxId: String) {
        guard var profile = findProfile(inboxId: inboxId) else { return }
        profile.clearEncryptedImage()
        profile.clearImage()
        upsertProfile(profile)
    }
}
