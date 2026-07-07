@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Guards that verified-agent discovery reads canonical `DBProfile` (joined to
/// the roster) rather than the legacy per-conversation `DBMemberProfile`, so an
/// agent learned only from a streamed profile message is still found.
@Suite("AgentBuilderConnectionGrantReplayer verified-agent discovery", .serialized)
struct AgentBuilderConnectionGrantReplayerTests {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        return dbQueue
    }

    private func seedMember(_ db: Database, conversationId: String, inboxId: String) throws {
        try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        try DBConversationMember(
            conversationId: conversationId,
            inboxId: inboxId,
            role: .member,
            consent: .allowed,
            createdAt: Date(),
            invitedByInboxId: nil
        ).save(db)
    }

    private func seedConversation(_ db: Database, id: String) throws {
        try DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "tag-\(id)",
            creatorId: "self",
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
            hasHadVerifiedAgent: false
        ).insert(db)
    }

    @Test("returns verified agents from canonical DBProfile, skipping humans")
    func findsVerifiedAgentFromCanonical() throws {
        let db = try makeDatabase()
        let conversationId = "c1"
        try db.write { db in
            try seedConversation(db, id: conversationId)
            try seedMember(db, conversationId: conversationId, inboxId: "agent")
            try seedMember(db, conversationId: conversationId, inboxId: "human")
            // Verified agent identity in canonical `profile`, no `memberProfile`.
            try DBProfile(inboxId: "agent", memberKind: .verifiedConvos, profileSource: .profileUpdate, updatedAt: Date()).save(db)
            try DBProfile(inboxId: "human", profileSource: .profileUpdate, updatedAt: Date()).save(db)
        }

        let ids = try db.read { db in
            try AgentBuilderConnectionGrantReplayer.verifiedAgentInboxIds(db: db, conversationId: conversationId)
        }
        #expect(ids == ["agent"])
    }

    @Test("excludes an unverified agent")
    func excludesUnverifiedAgent() throws {
        let db = try makeDatabase()
        let conversationId = "c1"
        try db.write { db in
            try seedConversation(db, id: conversationId)
            try seedMember(db, conversationId: conversationId, inboxId: "agent")
            // A plain (unverified) agent kind should not be returned.
            try DBProfile(inboxId: "agent", memberKind: .agent, profileSource: .profileUpdate, updatedAt: Date()).save(db)
        }

        let ids = try db.read { db in
            try AgentBuilderConnectionGrantReplayer.verifiedAgentInboxIds(db: db, conversationId: conversationId)
        }
        #expect(ids.isEmpty)
    }
}
