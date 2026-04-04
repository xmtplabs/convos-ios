import Foundation
import GRDB

public protocol DMLinksRepositoryProtocol: Sendable {
    func findDMConversationId(originConversationId: String, memberInboxId: String) async throws -> String?
    func findByConvoTag(_ convoTag: String) async throws -> DBDMLink?
    func hasPendingDMForMember(inConversation conversationId: String) async throws -> Bool
    func hasPendingDMForAnyMember(memberInboxIds: [String]) async throws -> Bool
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

    func hasPendingDMForMember(inConversation conversationId: String) async throws -> Bool {
        try await databaseReader.read { db in
            try DBDMLink
                .filter(DBDMLink.Columns.dmConversationId == conversationId)
                .fetchCount(db) > 0
        }
    }

    func hasPendingDMForAnyMember(memberInboxIds: [String]) async throws -> Bool {
        try await databaseReader.read { db in
            try DBDMLink
                .filter(memberInboxIds.contains(DBDMLink.Columns.memberInboxId))
                .filter(DBDMLink.Columns.dmConversationId.like("pending-%"))
                .fetchCount(db) > 0
        }
    }
}
