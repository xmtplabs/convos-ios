import ConvosInvites
import Foundation

extension SignedInvite {
    /// Signs an invite slug for a DB conversation. The caller supplies
    /// `creatorInboxId` from the identity it's signing with.
    static func slug(
        for conversation: DBConversation,
        creatorInboxId: String,
        expiresAt: Date?,
        expiresAfterUse: Bool,
        privateKey: Data
    ) throws -> String {
        let emoji = conversation.conversationEmoji
            ?? EmojiSelector.emoji(for: conversation.clientConversationId)
        return try createSlug(
            conversationId: conversation.id,
            creatorInboxId: creatorInboxId,
            privateKey: privateKey,
            tag: conversation.inviteTag,
            options: InviteSlugOptions(
                name: conversation.name,
                description: conversation.description,
                imageURL: conversation.publicImageURLString,
                emoji: emoji,
                expiresAt: expiresAt,
                expiresAfterUse: expiresAfterUse,
                conversationExpiresAt: conversation.expiresAt,
                includePublicPreview: conversation.includeInfoInPublicPreview
            )
        )
    }
}
