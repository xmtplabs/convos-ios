import Foundation
import GRDB

public protocol ThinkingControlWriterProtocol: Sendable {
    /// Persist one decoded `convos.org/thinking-control:1.0` event as a
    /// control row. Idempotent on `messageId` (the XMTP message id of the
    /// codec message), so the stream echo of a locally sent control or a
    /// catch-up re-delivery is a no-op.
    func apply(
        event: ThinkingControlContent,
        messageId: String,
        conversationId: String,
        senderInboxId: String,
        sentAtNs: Int64
    ) async
}

public final class ThinkingControlWriter: ThinkingControlWriterProtocol, Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func apply(
        event: ThinkingControlContent,
        messageId: String,
        conversationId: String,
        senderInboxId: String,
        sentAtNs: Int64
    ) async {
        do {
            try await databaseWriter.write { db in
                // The wire payload carries the XMTP server-assigned target
                // message id. Thinking moments store the local
                // `clientMessageId` (see `ThinkingSessionWriter`), and the
                // repository joins control rows to sessions by target id,
                // so resolve the same way to keep the keys aligned.
                let resolvedTargetId: String = try DBMessage
                    .filter(DBMessage.Columns.id == event.targetMessageId)
                    .fetchOne(db)
                    .map(\.clientMessageId)
                    ?? event.targetMessageId

                let control = DBThinkingControl(
                    id: messageId,
                    conversationId: conversationId,
                    senderInboxId: senderInboxId,
                    agentInboxId: event.agentInboxId,
                    targetMessageId: resolvedTargetId,
                    action: event.action.rawValue,
                    sentAtNs: sentAtNs
                )
                try control.save(db)
            }
        } catch {
            Log.warning("Failed to apply thinking control: \(error.localizedDescription)")
        }
    }
}
