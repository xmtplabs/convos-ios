import Foundation

/// Result of encrypting plaintext avatar bytes; cached on a publish job so a
/// restart re-uploads identical ciphertext without re-encrypting.
struct EncryptedAvatarPayload: Sendable {
    let ciphertext: Data
    let salt: Data
    let nonce: Data
}

/// A fully-resolved avatar reference, ready to advertise in a ProfileUpdate and
/// store in the local avatar slot.
struct PublishedAvatar: Sendable {
    let url: String
    let salt: Data
    let nonce: Data
    let key: Data
}

/// The XMTP- and upload-facing seam the publisher delegates to, keeping
/// `ProfilePublisher` (and ConvosCore) free of XMTPiOS. The messaging layer
/// provides the concrete implementation when the publisher is wired up.
protocol ProfilePublishSession: Sendable {
    /// All conversations the current user can publish their profile to.
    func conversationIds() async throws -> [String]

    /// The conversation's image-encryption (group) key, or nil if the
    /// conversation no longer exists - in which case its publish job is dropped.
    func imageKey(conversationId: String) async throws -> Data?

    /// Encrypts plaintext avatar bytes under the conversation's group key.
    func encrypt(_ plaintext: Data, groupKey: Data) throws -> EncryptedAvatarPayload

    /// Uploads ciphertext, returning the URL it can be fetched from.
    func upload(_ ciphertext: Data, filename: String) async throws -> String

    /// Sends a ProfileUpdate carrying the name, metadata, and (optional) avatar
    /// to one conversation.
    func sendProfileUpdate(name: String?, metadata: ProfileMetadata?, avatar: PublishedAvatar?, conversationId: String) async throws
}
