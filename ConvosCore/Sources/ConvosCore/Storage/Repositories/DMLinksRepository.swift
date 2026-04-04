import Foundation
import GRDB

public protocol DMLinksRepositoryProtocol: Sendable {
    func findDMConversationId(originConversationId: String, memberInboxId: String) async throws -> String?
    func findByConvoTag(_ convoTag: String) async throws -> DBDMLink?
}

final class DMLinksRepository: DMLinksRepositoryProtocol, @unchecked Sendable {
    private let databaseReader: any DatabaseReader

    init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    func findDMConversationId(originConversationId: String, memberInboxId: String) async throws -> String? {
        try await databaseReader.read { db in
            try DBDMLink
                .filter(DBDMLink.Columns.originConversationId == originConversationId)
                .filter(DBDMLink.Columns.memberInboxId == memberInboxId)
                .fetchOne(db)?
                .dmConversationId
        }
    }

    func findByConvoTag(_ convoTag: String) async throws -> DBDMLink? {
        try await databaseReader.read { db in
            try DBDMLink
                .filter(DBDMLink.Columns.convoTag == convoTag)
                .fetchOne(db)
        }
    }
}
