import Foundation
@preconcurrency import XMTPiOS

/// Single source of truth for how a backlog ("caught up") message is
/// classified, shared by every ingest path so they cannot drift:
///   - real-time stream (`StreamProcessor`)
///   - stream catch-up (`ConversationWriter.fetchAndStoreLatestMessages`)
///   - batch catch-up (`BatchCatchUp` + `ConversationWriter.applyBacklogSupplementals`)
///
/// Three separate copies of this routing previously diverged, which caused
/// backlog messages to be marked unread in the conversation the user was
/// viewing, to skip QA "received" events, and to persist thinking messages
/// as normal chat rows. Each path maps a `CaughtUpMessageKind` onto its own
/// handling, but the classification itself lives here once.
enum CaughtUpMessageKind {
    /// Profile updates/snapshots, typing indicators, or content with no
    /// decodable type. None of these are stored as chat messages on the
    /// catch-up paths (profiles are applied by the profile handlers, typing
    /// is live-only, and a message with no resolvable content type can't be
    /// rendered).
    case ignore
    case readReceipt
    case thinking
    /// Silent agent-builder bundle manifest. Lists the prepared XMTP ids of a
    /// builder bundle so every client hides them; stored via
    /// `storeBuilderBundleManifest`, never rendered as a chat row.
    case builderBundleManifest
    case reaction
    /// Text, attachments, link previews, group updates, etc. -> the regular
    /// message writer (`IncomingMessageWriter.store` / `persist`).
    case regular

    static func of(_ message: XMTPiOS.DecodedMessage) -> CaughtUpMessageKind {
        if message.isProfileMessage || message.isTypingIndicator {
            return .ignore
        }
        if message.isReadReceipt {
            return .readReceipt
        }
        if message.isThinking {
            return .thinking
        }
        if message.isBuilderBundleManifest {
            return .builderBundleManifest
        }
        guard let contentType = try? message.encodedContent.type else {
            return .ignore
        }
        if contentType == ContentTypeReaction || contentType == ContentTypeReactionV2 {
            return .reaction
        }
        return .regular
    }
}

/// Whether a newly-persisted message should mark its conversation unread,
/// applied identically by every ingest path. A message marks unread when its
/// content type is user-visible (`marksConversationAsUnread`), it came from
/// someone other than us, and it isn't the conversation the user is currently
/// viewing. Pass `activeConversationId: nil` from contexts with no active
/// conversation (push, conversation discovery).
func marksConversationUnread(
    contentType: MessageContentType,
    senderInboxId: String,
    currentInboxId: String,
    conversationId: String,
    activeConversationId: String?
) -> Bool {
    contentType.marksConversationAsUnread
        && senderInboxId != currentInboxId
        && conversationId != activeConversationId
}
