@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Storage-contract coverage for the per-conversation "initial ProfileSnapshot
/// sent" marker (`DBConversationInitialSnapshot`). The marker is what keeps
/// `StreamProcessor.sendInitialProfileSnapshotIfNeeded` to one first broadcast
/// per conversation across stream/catch-up redelivery. This validates that the
/// `createConversationInitialSnapshot` migration builds the table, that the
/// presence predicate the gate uses behaves, and that the row is cascade-deleted
/// with its conversation.
@Suite("Initial ProfileSnapshot marker", .serialized)
struct InitialProfileSnapshotMarkerTests {
    private static let conversationId = "conv-1"

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        return dbQueue
    }

    private func seedConversation(_ db: Database, id: String) throws {
        try DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "tag-\(id)",
            creatorId: "self-inbox",
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: true,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAgent: false,
            isAgentDm: false,
            isHumanDm: false
        ).insert(db)
    }

    /// The predicate `sendInitialProfileSnapshotIfNeeded` reads before sending.
    private func hasSentMarker(_ db: Database, conversationId: String) throws -> Bool {
        try DBConversationInitialSnapshot
            .filter(DBConversationInitialSnapshot.Columns.conversationId == conversationId)
            .fetchCount(db) > 0
    }

    @Test("Absent before a snapshot is sent, present after it is stamped")
    func markerGatesFirstSend() throws {
        let db = try makeDatabase()
        try db.write { db in
            try seedConversation(db, id: Self.conversationId)

            #expect(try hasSentMarker(db, conversationId: Self.conversationId) == false)

            try DBConversationInitialSnapshot(
                conversationId: Self.conversationId,
                sentAt: Date()
            ).save(db)

            #expect(try hasSentMarker(db, conversationId: Self.conversationId) == true)
        }
    }

    @Test("Marker is cascade-deleted with its conversation")
    func markerCascadesWithConversation() throws {
        let db = try makeDatabase()
        try db.write { db in
            try seedConversation(db, id: Self.conversationId)
            try DBConversationInitialSnapshot(
                conversationId: Self.conversationId,
                sentAt: Date()
            ).save(db)
            #expect(try hasSentMarker(db, conversationId: Self.conversationId) == true)

            try DBConversation.deleteOne(db, id: Self.conversationId)

            #expect(try hasSentMarker(db, conversationId: Self.conversationId) == false)
        }
    }
}
