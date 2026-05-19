import Foundation
import GRDB

public protocol ThinkingSessionWriterProtocol: Sendable {
    /// Persist one decoded `convos.org/thinking:1.0` event as a moment row.
    /// Idempotent on `momentId` (the XMTP message id of the codec message),
    /// so re-delivery of the same event is a no-op. Each agent `start` adds
    /// a moment to the session's history; each `stop` closes it.
    func apply(
        event: ThinkingContent,
        momentId: String,
        conversationId: String,
        senderInboxId: String,
        sentAtNs: Int64
    ) async
}

public final class ThinkingSessionWriter: ThinkingSessionWriterProtocol, Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func apply(
        event: ThinkingContent,
        momentId: String,
        conversationId: String,
        senderInboxId: String,
        sentAtNs: Int64
    ) async {
        do {
            try await databaseWriter.write { db in
                // The agent's codec payload carries the XMTP server-assigned
                // message id. The UI keys messages by `Message.id`, which is
                // the local `clientMessageId` (a UUID for messages we sent
                // optimistically). Resolve at write time so the moment's
                // `targetMessageId` / `resultMessageId` match whatever the
                // UI iterates by — when the target isn't yet locally known,
                // fall back to the server id (rare; late-arriving targets
                // stay unmatched).
                let resolvedTargetId: String = try DBMessage
                    .filter(DBMessage.Columns.id == event.targetMessageId)
                    .fetchOne(db)
                    .map(\.clientMessageId)
                    ?? event.targetMessageId
                let resolvedResultMessageId: String? = try event.resultMessageId.flatMap { serverId in
                    try DBMessage
                        .filter(DBMessage.Columns.id == serverId)
                        .fetchOne(db)
                        .map(\.clientMessageId)
                } ?? event.resultMessageId

                let moment = DBThinkingMoment(
                    id: momentId,
                    conversationId: conversationId,
                    senderInboxId: senderInboxId,
                    targetMessageId: resolvedTargetId,
                    state: event.state.rawValue,
                    content: event.content,
                    sentAtNs: sentAtNs,
                    resultMessageId: resolvedResultMessageId
                )
                try moment.save(db)
            }
        } catch {
            Log.warning("Failed to apply thinking moment: \(error.localizedDescription)")
        }
    }
}
