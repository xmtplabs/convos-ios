import ConvosInvites
import Foundation

extension SignedInvite {
    static func slug(
        for conversation: DBConversation,
        expiresAt: Date?,
        expiresAfterUse: Bool,
        privateKey: Data
    ) throws -> String {
        try createSlug(
            conversationId: conversation.id,
            creatorInboxId: conversation.inboxId,
            privateKey: privateKey,
            tag: conversation.inviteTag,
            options: InviteSlugOptions(
                name: conversation.name,
                description: conversation.description,
                imageURL: conversation.publicImageURLString,
                emoji: conversation.conversationEmoji,
                expiresAt: expiresAt,
                expiresAfterUse: expiresAfterUse,
                conversationExpiresAt: conversation.expiresAt,
                includePublicPreview: conversation.includeInfoInPublicPreview
            )
        )
    }
}
