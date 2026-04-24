import Foundation
import GRDB

public struct ReadReceiptEntry: Sendable {
    public let inboxId: String
    public let readAtNs: Int64
}

public protocol ReadReceiptWriterProtocol: Sendable {
    func sendReadReceipt(for conversationId: String) async throws
}

enum ReadReceiptWriterError: Error {
    case missingClientProvider
    case conversationNotFound
    case notSupportedOnDTU
}

// Stage 3 migration (audit §5.3): the writer no longer imports
// XMTPiOS. It goes through the abstraction-layer
// `messagingConversation(with:)` convenience to fetch the conversation,
// then uses the XMTPiOS-specific `MessageSender.sendReadReceipt()`
// method via the Stage 4 `underlyingXMTPiOSConversation` bridge.
// Once Stage 6 migrates the ReadReceiptCodec off XMTPiOS the bridge
// can be removed and the writer can call a Messaging* equivalent.
final class ReadReceiptWriter: ReadReceiptWriterProtocol, Sendable {
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter

    init(
        inboxStateManager: any InboxStateManagerProtocol,
        databaseWriter: any DatabaseWriter
    ) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
    }

    func sendReadReceipt(for conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client
            .messagingConversation(with: conversationId) else {
            throw ReadReceiptWriterError.conversationNotFound
        }

        // FIXME(stage6): the ReadReceipt codec still lives in the
        // XMTPiOS custom-content-types package. Fall through to the
        // `underlyingXMTPiOSConversation` bridge until Stage 6 migrates
        // the codec (and adds a Messaging* `sendReadReceipt` hook on
        // `MessagingConversationCore`).
        try await sendReadReceiptViaBridge(conversation: conversation)

        let sentAtNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        try await databaseWriter.write { db in
            let receipt = DBConversationReadReceipt(
                conversationId: conversationId,
                inboxId: inboxReady.client.inboxId,
                readAtNs: sentAtNs
            )
            try receipt.save(db, onConflict: .replace)
        }

        Log.info("Sent read receipt for conversation \(conversationId)")
    }
}

extension DBConversationReadReceipt {
    enum Columns: String, ColumnExpression {
        case conversationId, inboxId, readAtNs
    }
}
