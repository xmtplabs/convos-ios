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

// The writer fetches the conversation through
// `messagingConversation(with:)` and sends the receipt through the
// `underlyingXMTPiOSConversation` bridge — the ReadReceipt codec still
// lives in the XMTPiOS layer, so the bridge stays until the codec
// migrates onto the abstraction.
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

        // FIXME: see docs/outstanding-messaging-abstraction-work.md#codec-migration
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
