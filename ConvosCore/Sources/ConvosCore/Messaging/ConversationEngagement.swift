import Foundation
import GRDB

/// Single source of truth for whether a minted conversation counts as
/// "engaged" - i.e. whether implicit dismiss-cleanup is allowed to discard
/// it. A freshly pooled row is written with all-nil metadata
/// (`UnusedConversationCache.writeUnusedConversationRow`), no messages, and
/// the creator as its only member, so engagement is detectable as any
/// deviation from that baseline:
///
/// - any metadata customization: non-nil, non-empty `name`, `description`,
///   or `conversationEmoji`, or a non-nil `imageURLString`;
/// - any chat message (the `.messages` grouping notion the messages list
///   counts - system rows like membership updates do not qualify);
/// - another member right now, or ever
///   (`ConversationLocalState.hasHadOtherMembers` survives the member's
///   row being deleted on departure sync).
///
/// Unsent composer drafts deliberately do not count: draft text is not
/// persisted anywhere, so keeping the conversation for one would surface an
/// empty row with the draft lost. If drafts ever gain persistence, add a
/// draft check here.
///
/// Used by `SessionManager.discardClaimedConversationIfUnengaged` as the
/// authoritative gate before a claimed conversation is destroyed. The view
/// model layer keeps its own synchronous latches for in-flight writes that
/// have not landed in the database yet.
enum ConversationEngagement {
    /// Content types that render inside `.messages` groups in the messages
    /// list - the same set `[MessagesListItemType].countMessages` counts.
    /// Membership/metadata updates and agent/connection system rows render
    /// as their own list item types and are excluded.
    static let chatMessageContentTypes: [MessageContentType] = [
        .text, .emoji, .attachments, .invite, .agentShare, .linkPreview,
    ]

    static func isEngaged(_ db: Database, conversationId: String, currentInboxId: String?) throws -> Bool {
        guard let conversation = try DBConversation.fetchOne(db, key: conversationId) else {
            return false
        }
        if hasCustomizedMetadata(conversation) {
            return true
        }
        // Minted rows are created by the local inbox, so the creator is a
        // safe fallback identity for "self" when no inbox row exists yet.
        let selfInboxId = currentInboxId ?? conversation.creatorId
        let otherMemberCount = try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .filter(DBConversationMember.Columns.inboxId != selfInboxId)
            .fetchCount(db)
        if otherMemberCount > 0 {
            return true
        }
        let localState = try ConversationLocalState
            .filter(ConversationLocalState.Columns.conversationId == conversationId)
            .fetchOne(db)
        if localState?.hasHadOtherMembers == true {
            return true
        }
        return try hasChatMessages(db, conversationId: conversationId)
    }

    /// Non-nil, non-empty on any of the four customizable columns. The pool
    /// writes them all nil; "New Convo" is a UI-only fallback that never
    /// reaches the database. Empty strings can appear when a user reverts a
    /// customization (e.g. clears the name), and count as not customized so
    /// a reverted conversation found on a later launch is discardable again.
    static func hasCustomizedMetadata(_ conversation: DBConversation) -> Bool {
        if isNonEmpty(conversation.name) || isNonEmpty(conversation.description) || isNonEmpty(conversation.conversationEmoji) {
            return true
        }
        return conversation.imageURLString != nil
    }

    private static func hasChatMessages(_ db: Database, conversationId: String) throws -> Bool {
        let chatTypes = chatMessageContentTypes.map(\.rawValue)
        let count = try DBMessage
            .filter(DBMessage.Columns.conversationId == conversationId)
            .filter(DBMessage.Columns.messageType != DBMessageType.reaction.rawValue)
            .filter(chatTypes.contains(DBMessage.Columns.contentType))
            .fetchCount(db)
        return count > 0
    }

    private static func isNonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty
    }
}
