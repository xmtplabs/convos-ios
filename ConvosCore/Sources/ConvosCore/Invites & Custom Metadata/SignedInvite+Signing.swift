import Foundation
import SwiftProtobuf

// MARK: - SignedInvite + Signing

/// Extensions for cryptographically signed conversation invites
///
/// Convos uses a secure invite system based on secp256k1 signatures:
///
/// **Invite Creation Flow:**
/// 1. Creator generates an invite containing: conversation token (encrypted conversation ID),
///    invite tag, metadata (name, image, description), and optional expiry
/// 2. Creator signs the invite payload with their private key
/// 3. Invite is compressed with DEFLATE and encoded to a URL-safe base64 string
///
/// **Join Request Flow:**
/// 1. Joiner receives invite code (QR, link, airdrop, etc.)
/// 2. Joiner sends the invite code as a text message in a DM to the creator
/// 3. Creator's app validates signature and decrypts conversation token
/// 4. If valid, creator adds joiner to the conversation
///
/// **Security Properties:**
/// - Only the creator can decrypt the conversation ID (via encrypted token)
/// - Signature proves the invite was created by conversation owner
/// - Public key can be recovered from signature for verification
/// - Invites can have expiration dates and single-use flags
/// - Invalid invites result in blocked DMs to prevent spam
extension SignedInvite {
    static func slug(
        for conversation: DBConversation,
        expiresAt: Date?,
        expiresAfterUse: Bool,
        privateKey: Data,
    ) throws -> String {
        let conversationTokenBytes = try InviteConversationToken.makeConversationTokenBytes(
            conversationId: conversation.id,
            creatorInboxId: conversation.inboxId,
            secp256k1PrivateKey: privateKey
        )
        var payload = InvitePayload()
        if let name = conversation.name {
            payload.name = name
        }
        if let description_p = conversation.description {
            payload.description_p = description_p
        }
        if let imageURL = conversation.imageURLString {
            payload.imageURL = imageURL
        }
        if let conversationExpiresAt = conversation.expiresAt {
            payload.conversationExpiresAtUnix = Int64(conversationExpiresAt.timeIntervalSince1970)
        }
        payload.expiresAfterUse = expiresAfterUse
        payload.tag = conversation.inviteTag
        payload.conversationToken = conversationTokenBytes

        // Convert hex-encoded inbox ID to raw bytes
        guard let inboxIdBytes = Data(hexString: conversation.inboxId), !inboxIdBytes.isEmpty else {
            throw EncodableSignatureError.invalidFormat
        }
        payload.creatorInboxID = inboxIdBytes

        if let expiresAt {
            payload.expiresAtUnix = Int64(expiresAt.timeIntervalSince1970)
        }
        let signature = try payload.sign(with: privateKey)
        var signedInvite = SignedInvite()
        // Store the serialized payload bytes to preserve the exact bytes that were signed
        signedInvite.payload = try payload.serializedData()
        signedInvite.signature = signature
        return try signedInvite.toURLSafeSlug()
    }
}
