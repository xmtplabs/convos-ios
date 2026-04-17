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
            // C11c: the conversation table no longer carries a clientId, so
            // the old JOIN inbox↔conversation on clientId is gone. In
            // single-inbox mode there's at most one inbox row, so "orphan"
            // collapses to "the sole inbox exists but there are no joined
            // (non-draft) conversations and no drafts with invite tags". If
            // that condition holds, return the inbox with any draft ids
            // attached.
            let inboxSql = """
                SELECT clientId, inboxId, createdAt FROM inbox ORDER BY createdAt ASC
                """
            let inboxRows = try Row.fetchAll(db, sql: inboxSql)
            return try inboxRows.compactMap { row -> OrphanedInboxDetail? in
                let nonDraftCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM conversation WHERE id NOT LIKE 'draft-%'"
                ) ?? 0
                if nonDraftCount > 0 { return nil }
                let taggedDraftCount = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM conversation
                    WHERE id LIKE 'draft-%' AND inviteTag IS NOT NULL AND length(inviteTag) > 0
                    """
                ) ?? 0
                if taggedDraftCount > 0 { return nil }
                let draftIds = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM conversation WHERE id LIKE 'draft-%'"
                )
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
