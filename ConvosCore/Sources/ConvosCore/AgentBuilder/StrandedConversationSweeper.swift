import Foundation
import GRDB

/// One-shot session-start sweep that hides conversation shells stranded by
/// interrupted creation flows: visible, self-created rows that never got a
/// name, an image, another member, a shared invite, or any real content.
///
/// The agent-DM create path used to surface such shells at scale: its
/// ready-wait timed out mid-setup while the conversation still published,
/// so the marker stamp and agent add never ran and the conversation was
/// left rendering as "New Convo" in the list - one per agent per session.
/// The create path now defers visibility until setup completes, so no new
/// shells form; this sweep cleans up the ones already stranded on affected
/// devices.
///
/// Sweeping flips rows back to `isUnused`, the same hidden state
/// deferred-visibility creation uses: they leave the list immediately, and
/// cache-shaped rows return to the prewarm pool instead of being wasted.
enum StrandedConversationSweeper {
    /// Hides stranded shells created before `now - minimumAge`; returns how
    /// many rows were hidden.
    @discardableResult
    static func sweep(databaseWriter: any DatabaseWriter, now: Date = Date()) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Constant.minimumAge)
        return try await databaseWriter.write { (db: Database) -> Int in
            // Every predicate is a positive signal the user never touched the
            // conversation. `contentType <> 'update'` (rather than a last-
            // message pointer) is the content check because stranded shells
            // do receive their own metadata commits as update messages.
            try db.execute(
                sql: """
                UPDATE conversation SET isUnused = 1
                WHERE isUnused = 0
                  AND isAgentDm = 0
                  AND id NOT LIKE 'draft-%'
                  AND (name IS NULL OR name = '')
                  AND (description IS NULL OR description = '')
                  AND imageURLString IS NULL
                  AND createdAt < ?
                  AND creatorId IN (SELECT inboxId FROM inbox)
                  AND NOT EXISTS (
                      SELECT 1 FROM conversation_members cm
                      WHERE cm.conversationId = conversation.id
                        AND cm.inboxId NOT IN (SELECT inboxId FROM inbox)
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM message m
                      WHERE m.conversationId = conversation.id
                        AND m.contentType <> 'update'
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM conversationLocalState ls
                      WHERE ls.conversationId = conversation.id
                        AND (ls.isPinned = 1 OR ls.hasSharedInvite = 1 OR ls.hasHadOtherMembers = 1)
                  )
                """,
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }

    private enum Constant {
        /// Rows must be at least this old before they are considered
        /// stranded, so the sweep can never race a creation still
        /// legitimately in flight or hide an empty conversation the user
        /// just made and is about to use.
        static let minimumAge: TimeInterval = 24 * 60 * 60
    }
}
