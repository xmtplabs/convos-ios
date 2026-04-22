import Combine
import Foundation
import GRDB

public struct PendingInviteDetail: Codable, Hashable, Identifiable, Sendable {
    public var id: String { conversationId }
    public let conversationId: String
    public let inviteTag: String
    public let conversationName: String?
    public let createdAt: Date
    public let memberCount: Int

    public init(
        conversationId: String,
        inviteTag: String,
        conversationName: String?,
        createdAt: Date,
        memberCount: Int = 0
    ) {
        self.conversationId = conversationId
        self.inviteTag = inviteTag
        self.conversationName = conversationName
        self.createdAt = createdAt
        self.memberCount = memberCount
    }
}

/// Read-only view over the local user's pending (draft + tagged) invites.
public protocol PendingInviteRepositoryProtocol {
    /// Returns one `PendingInviteDetail` per pending draft conversation, ordered
    /// by `createdAt` ascending. Used by the debug surface.
    func allPendingInviteDetails() throws -> [PendingInviteDetail]
}

public struct PendingInviteRepository: PendingInviteRepositoryProtocol {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func allPendingInviteDetails() throws -> [PendingInviteDetail] {
        try databaseReader.read { db in
            let sql = """
                SELECT
                    c.id as conversationId,
                    c.inviteTag,
                    c.name,
                    c.createdAt,
                    (SELECT COUNT(*) FROM conversation_members cm WHERE cm.conversationId = c.id) as memberCount
                FROM conversation c
                WHERE c.id LIKE 'draft-%'
                    AND c.inviteTag IS NOT NULL
                    AND c.inviteTag != ''
                ORDER BY c.createdAt ASC
                """

            return try Row.fetchAll(db, sql: sql).map { row in
                PendingInviteDetail(
                    conversationId: row["conversationId"],
                    inviteTag: row["inviteTag"],
                    conversationName: row["name"],
                    createdAt: row["createdAt"],
                    memberCount: row["memberCount"]
                )
            }
        }
    }
}

public final class MockPendingInviteRepository: PendingInviteRepositoryProtocol, @unchecked Sendable {
    public var pendingInviteDetails: [PendingInviteDetail] = []

    public init() {}

    public func allPendingInviteDetails() throws -> [PendingInviteDetail] {
        pendingInviteDetails
    }
}
