import Foundation
import GRDB

public protocol DMLinksWriterProtocol: Sendable {
    func store(
        originConversationId: String,
        memberInboxId: String,
        dmConversationId: String,
        convoTag: String
    ) async throws
    func updateConversationId(memberInboxId: String, newConversationId: String) async throws
}

final class DMLinksWriter: DMLinksWriterProtocol, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter

    init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    func store(
        originConversationId: String,
        memberInboxId: String,
        dmConversationId: String,
        convoTag: String
    ) async throws {
        try await databaseWriter.write { db in
            let link = DBDMLink(
                originConversationId: originConversationId,
                memberInboxId: memberInboxId,
                dmConversationId: dmConversationId,
                convoTag: convoTag,
                createdAt: Date()
            )
            try link.save(db)
        }
    }

    func updateConversationId(memberInboxId: String, newConversationId: String) async throws {
        try await databaseWriter.write { db in
            try db.execute(
                sql: "UPDATE dmLink SET dmConversationId = ? WHERE memberInboxId = ? AND dmConversationId LIKE 'pending-%'",
                arguments: [newConversationId, memberInboxId]
            )
        }
    }
}
