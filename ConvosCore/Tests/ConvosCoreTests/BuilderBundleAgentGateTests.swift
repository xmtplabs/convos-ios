@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for the agent-join gate that holds the builder-bundle publish
/// until the requested agent is a member of the conversation
/// (`OutgoingMessageWriter.waitForAgentMember`). The brief is addressed to a
/// joining agent, and XMTP members can't read messages sent before they
/// joined -- so the gate must open only on a CURRENT agent member (stale
/// profile rows for removed agents must not count) and must fall through on
/// timeout rather than strand the send.
@Suite("Builder bundle agent gate Tests", .serialized)
struct BuilderBundleAgentGateTests {
    private static let currentInboxId: String = "inbox-current"
    private static let humanInboxId: String = "inbox-human"
    private static let agentInboxId: String = "inbox-agent"
    private static let conversationId: String = "convo-gate"

    // MARK: - Seeding

    private static func seedConversation(db: Database) throws {
        for inboxId in [currentInboxId, humanInboxId, agentInboxId] {
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        }
        try DBInbox(
            inboxId: currentInboxId,
            clientId: "client-current",
            createdAt: Date()
        ).save(db, onConflict: .ignore)

        try DBConversation(
            id: conversationId,
            clientConversationId: "client-\(conversationId)",
            inviteTag: "tag-\(conversationId)",
            creatorId: currentInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
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

        try addMember(db: db, inboxId: currentInboxId, kind: nil)
        try addMember(db: db, inboxId: humanInboxId, kind: nil)
    }

    private static func addMember(db: Database, inboxId: String, kind: DBMemberKind?) throws {
        try DBConversationMember(
            conversationId: conversationId,
            inboxId: inboxId,
            role: .member,
            consent: .allowed,
            createdAt: Date(),
            invitedByInboxId: nil
        ).insert(db)
        try DBMemberProfile(
            conversationId: conversationId,
            inboxId: inboxId,
            name: inboxId,
            avatar: nil,
            memberKind: kind
        ).insert(db, onConflict: .ignore)
    }

    /// An agent that has a profile row (never deleted on removal) but no
    /// current `DBConversationMember` row -- the shape left behind after the
    /// agent was removed from the group.
    private static func addStaleAgentProfile(db: Database) throws {
        try DBMemberProfile(
            conversationId: conversationId,
            inboxId: agentInboxId,
            name: agentInboxId,
            avatar: nil,
            memberKind: .verifiedConvos
        ).insert(db, onConflict: .ignore)
    }

    // MARK: - hasCurrentAgentMember

    @Test("No agent member: predicate is false")
    func testNoAgentMember() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
        }
        let hasAgent = try dbManager.dbReader.read { db in
            try OutgoingMessageWriter.hasCurrentAgentMember(db: db, conversationId: Self.conversationId)
        }
        #expect(hasAgent == false)
    }

    @Test("Current agent member opens the predicate, even unverified")
    func testCurrentAgentMember() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
            try Self.addMember(db: db, inboxId: Self.agentInboxId, kind: .agent)
        }
        let hasAgent = try dbManager.dbReader.read { db in
            try OutgoingMessageWriter.hasCurrentAgentMember(db: db, conversationId: Self.conversationId)
        }
        #expect(hasAgent == true)
    }

    @Test("Stale agent profile without current membership does not open the predicate")
    func testStaleAgentProfileDoesNotCount() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
            try Self.addStaleAgentProfile(db: db)
        }
        let hasAgent = try dbManager.dbReader.read { db in
            try OutgoingMessageWriter.hasCurrentAgentMember(db: db, conversationId: Self.conversationId)
        }
        #expect(hasAgent == false)
    }

    @Test("Agent member in a different conversation does not open the predicate")
    func testOtherConversationAgentDoesNotCount() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
        }
        let hasAgent = try dbManager.dbReader.read { db in
            try OutgoingMessageWriter.hasCurrentAgentMember(db: db, conversationId: "some-other-convo")
        }
        #expect(hasAgent == false)
    }

    // MARK: - waitForAgentMember

    @Test("Gate opens immediately when an agent is already a member")
    func testGateOpensImmediately() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
            try Self.addMember(db: db, inboxId: Self.agentInboxId, kind: .verifiedConvos)
        }
        let joined = await OutgoingMessageWriter.waitForAgentMember(
            in: dbManager.dbReader,
            conversationId: Self.conversationId,
            timeout: 5
        )
        #expect(joined == true)
    }

    @Test("Gate opens when the agent member row arrives mid-wait")
    func testGateOpensOnJoin() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
        }
        let writer = dbManager.dbWriter
        Task {
            try await Task.sleep(nanoseconds: 300_000_000)
            try await writer.write { db in
                try Self.addMember(db: db, inboxId: Self.agentInboxId, kind: .agent)
            }
        }
        let joined = await OutgoingMessageWriter.waitForAgentMember(
            in: dbManager.dbReader,
            conversationId: Self.conversationId,
            timeout: 10
        )
        #expect(joined == true)
    }

    @Test("Gate times out and falls through when no agent ever joins")
    func testGateTimesOut() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db)
            try Self.addStaleAgentProfile(db: db)
        }
        let start = Date()
        let joined = await OutgoingMessageWriter.waitForAgentMember(
            in: dbManager.dbReader,
            conversationId: Self.conversationId,
            timeout: 0.5
        )
        #expect(joined == false)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
