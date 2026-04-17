import ConvosInvites
import Foundation

extension SignedInvite {
    /// Signs an invite slug for a DB conversation. `creatorInboxId` is passed
    /// explicitly rather than read from the conversation row — the column was
    /// removed in C11c because in single-inbox mode every row belongs to the
    /// singleton identity and the caller already has that inboxId from the
    /// keychain identity it's signing with.
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
