import ConvosInvites
import Foundation

// MARK: - SignedInvite + Signing (Convos-specific)

/// Extensions for creating signed invites from Convos database conversations
///
/// This extends the ConvosInvites package with Convos-specific logic that
/// requires access to database models like DBConversation.
extension SignedInvite {
    /// Create a URL slug from a database conversation
    static func slug(
        for conversation: DBConversation,
        expiresAt: Date?,
        expiresAfterUse: Bool,
        privateKey: Data
    ) throws -> String {
        let conversationTokenBytes = try InviteToken.encrypt(
            conversationId: conversation.id,
            creatorInboxId: conversation.inboxId,
            privateKey: privateKey
        )

        var payload = InvitePayload()

        if conversation.includeInfoInPublicPreview {
            if let name = conversation.name {
                payload.name = name
            }
            if let description_p = conversation.description {
                payload.description_p = description_p
            }
            if let publicImageURL = conversation.publicImageURLString {
                payload.imageURL = publicImageURL
            }
        }

        if let conversationExpiresAt = conversation.expiresAt {
            payload.conversationExpiresAtUnix = Int64(conversationExpiresAt.timeIntervalSince1970)
        }

        payload.expiresAfterUse = expiresAfterUse
        payload.tag = conversation.inviteTag
        payload.conversationToken = conversationTokenBytes

        guard let inboxIdBytes = Data(hexString: conversation.inboxId), !inboxIdBytes.isEmpty else {
            throw InviteEncodingError.invalidBase64
        }
        payload.creatorInboxID = inboxIdBytes

        if let expiresAt {
            payload.expiresAtUnix = Int64(expiresAt.timeIntervalSince1970)
        }

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        return try signedInvite.toURLSafeSlug()
    }
}
