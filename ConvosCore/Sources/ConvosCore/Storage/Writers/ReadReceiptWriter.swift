import Foundation
import GRDB
import XMTPiOS

public protocol ReadReceiptWriterProtocol: Sendable {
    func sendReadReceipt(for conversationId: String) async throws
    func fetchReadMemberInboxIds(
        for conversationId: String,
        afterNs messageDateNs: Int64,
        excludingInboxId: String
    ) async throws -> [String]
}

enum ReadReceiptWriterError: Error {
    case missingClientProvider
    case conversationNotFound
}

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

    func fetchReadMemberInboxIds(
        for conversationId: String,
        afterNs messageDateNs: Int64,
        excludingInboxId: String
    ) async throws -> [String] {
        try await databaseWriter.read { db in
            try DBConversationReadReceipt
                .filter(DBConversationReadReceipt.Columns.conversationId == conversationId)
                .filter(DBConversationReadReceipt.Columns.readAtNs >= messageDateNs)
                .filter(DBConversationReadReceipt.Columns.inboxId != excludingInboxId)
                .select(DBConversationReadReceipt.Columns.inboxId)
                .asRequest(of: String.self)
                .fetchAll(db)
        }
    }
}

extension DBConversationReadReceipt {
    enum Columns: String, ColumnExpression {
        case conversationId, inboxId, readAtNs
    }
}
