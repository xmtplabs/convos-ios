import Foundation
import GRDB
import XMTPiOS

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
}

final class ReadReceiptWriter: ReadReceiptWriterProtocol, Sendable {
    private let sessionStateManager: any SessionStateManagerProtocol
    private let databaseWriter: any DatabaseWriter

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        databaseWriter: any DatabaseWriter
    ) {
        self.sessionStateManager = sessionStateManager
        self.databaseWriter = databaseWriter
    }

    func sendReadReceipt(for conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.conversationsProvider
            .findConversation(conversationId: conversationId) else {
            throw ReadReceiptWriterError.conversationNotFound
        }

        nonisolated(unsafe) let unsafeConversation = conversation
        try await unsafeConversation.sendReadReceipt()

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
