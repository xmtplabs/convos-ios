import Foundation
import GRDB

public protocol DMLinksWriterProtocol: Sendable {
    func store(
        originConversationId: String,
        memberInboxId: String,
        dmConversationId: String,
        convoTag: String
    ) async throws
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
}
