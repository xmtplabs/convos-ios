import Foundation
import GRDB

public struct OrphanedInboxDetail: Hashable, Identifiable, Sendable {
    public var id: String { clientId }
    public let clientId: String
    public let inboxId: String
    public let createdAt: Date
    public let draftConversationIds: [String]
    public let hasNonDraftConversations: Bool

    public init(
        clientId: String,
        inboxId: String,
        createdAt: Date,
        draftConversationIds: [String] = [],
        hasNonDraftConversations: Bool = false
    ) {
        self.clientId = clientId
        self.inboxId = inboxId
        self.createdAt = createdAt
        self.draftConversationIds = draftConversationIds
        self.hasNonDraftConversations = hasNonDraftConversations
    }
}

public protocol OrphanedInboxRepositoryProtocol: Sendable {
    func allOrphanedInboxes() throws -> [OrphanedInboxDetail]
}

public struct OrphanedInboxRepository: OrphanedInboxRepositoryProtocol, @unchecked Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func allOrphanedInboxes() throws -> [OrphanedInboxDetail] {
        try databaseReader.read { db in
            let sql = """
                SELECT
                    i.clientId,
                    i.inboxId,
                    i.createdAt,
                    GROUP_CONCAT(CASE WHEN c.id LIKE 'draft-%' THEN c.id END) as draftIds,
                    COUNT(CASE WHEN c.id NOT LIKE 'draft-%' THEN 1 END) as nonDraftCount
                FROM inbox i
                LEFT JOIN conversation c ON c.clientId = i.clientId
                WHERE NOT EXISTS (
                    SELECT 1 FROM conversation c2
                    WHERE c2.clientId = i.clientId
                        AND c2.id NOT LIKE 'draft-%'
                )
                AND NOT EXISTS (
                    SELECT 1 FROM conversation c3
                    WHERE c3.clientId = i.clientId
                        AND c3.id LIKE 'draft-%'
                        AND c3.inviteTag IS NOT NULL
                        AND length(c3.inviteTag) > 0
                )
                GROUP BY i.clientId, i.inboxId, i.createdAt
                ORDER BY i.createdAt ASC
                """

            return try Row.fetchAll(db, sql: sql).map { row in
                let draftIdsString: String? = row["draftIds"]
                let draftIds = draftIdsString?
                    .split(separator: ",")
                    .map { String($0) } ?? []

                return OrphanedInboxDetail(
                    clientId: row["clientId"],
                    inboxId: row["inboxId"],
                    createdAt: row["createdAt"],
                    draftConversationIds: draftIds,
                    hasNonDraftConversations: false
                )
            }
        }
    }
}
