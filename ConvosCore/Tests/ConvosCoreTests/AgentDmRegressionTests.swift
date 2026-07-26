@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Regression coverage for the agent-DM client behaviors that shipped with
/// CON-761 (see docs/plans/agent-dms.md and agent-dms-qa.md). Each test pins a
/// behavior that broke at least once during development:
/// - a DM leaking into the conversations list or count (hidden-set invariant)
/// - `findAgentDm` resolving the wrong 1:1 (builder convo shadowing the DM)
/// - the one-way classification latch (marker transiently rewritten off the
///   appData blob must not un-mark a DM)
@Suite("Agent DM regressions", .serialized)
struct AgentDmRegressionTests {
    private static let selfInbox = "self-inbox"
    private static let agentInbox = "agent-inbox"

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        return dbQueue
    }

    private func seedInbox(_ db: Database) throws {
        try DBInbox(inboxId: Self.selfInbox, clientId: "client-1", createdAt: Date()).insert(db)
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

    private func makeConversation(id: String, isAgentDm: Bool) -> DBConversation {
        DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "tag-\(id)",
            creatorId: Self.selfInbox,
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
            hasHadVerifiedAgent: true,
            isAgentDm: isAgentDm
        )
    }

    /// A live 2-member conversation with self + one other member, visible to
    /// the list joins (localState present, not removed).
    private func seedConversation(
        _ db: Database,
        id: String,
        isAgentDm: Bool,
        otherInboxId: String = AgentDmRegressionTests.agentInbox
    ) throws {
        try makeConversation(id: id, isAgentDm: isAgentDm).insert(db)
        try ConversationLocalState(
            conversationId: id,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: Date.distantPast,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            hasHadOtherMembers: true,
            hasSharedInvite: false
        ).insert(db)
        try seedMember(db, conversationId: id, inboxId: Self.selfInbox)
        try seedMember(db, conversationId: id, inboxId: otherInboxId)
    }

    @Test("agent DMs are hidden from the conversations list")
    func dmHiddenFromList() throws {
        let dbQueue = try makeDatabase()
        try dbQueue.write { db in
            try seedInbox(db)
            try seedConversation(db, id: "group-1", isAgentDm: false)
            try seedConversation(db, id: "dm-1", isAgentDm: true)
        }
        let repository = ConversationsRepository(dbReader: dbQueue, consent: [.allowed])
        let listed = try repository.fetchAll().map(\.id)
        #expect(listed.contains("group-1"))
        #expect(!listed.contains("dm-1"))
    }

    @Test("agent DMs do not count toward the conversations count")
    func dmExcludedFromCount() throws {
        let dbQueue = try makeDatabase()
        try dbQueue.write { db in
            try seedInbox(db)
            try seedConversation(db, id: "group-1", isAgentDm: false)
            try seedConversation(db, id: "dm-1", isAgentDm: true)
            try seedConversation(db, id: "dm-2", isAgentDm: true, otherInboxId: "agent-2")
        }
        let repository = ConversationsCountRepository(databaseReader: dbQueue, consent: [.allowed])
        #expect(try repository.fetchCount() == 1)
    }

    @Test("findAgentDm resolves only the marked DM, never the builder 1:1")
    func findAgentDmSelectivity() throws {
        let dbQueue = try makeDatabase()
        try dbQueue.write { db in
            try seedInbox(db)
            // The builder conversation is also a 2-member [self, agent] group;
            // without the marker filter it would shadow the DM.
            try seedConversation(db, id: "builder-1", isAgentDm: false)
            try seedConversation(db, id: "dm-1", isAgentDm: true)
        }
        let repository = ConversationsRepository(dbReader: dbQueue, consent: [.allowed])
        let dm = try repository.findAgentDm(with: Self.agentInbox)
        #expect(dm?.id == "dm-1")
    }

    @Test("findAgentDm is nil when only unmarked 1:1s exist")
    func findAgentDmNilWithoutMarker() throws {
        let dbQueue = try makeDatabase()
        try dbQueue.write { db in
            try seedInbox(db)
            try seedConversation(db, id: "builder-1", isAgentDm: false)
        }
        let repository = ConversationsRepository(dbReader: dbQueue, consent: [.allowed])
        #expect(try repository.findAgentDm(with: Self.agentInbox) == nil)
    }

    @Test("plain 1:1 lookup never resolves to an agent DM")
    func oneToOneExcludesAgentDm() throws {
        let dbQueue = try makeDatabase()
        try dbQueue.write { db in
            try seedInbox(db)
            try seedConversation(db, id: "dm-1", isAgentDm: true)
        }
        let repository = ConversationsRepository(dbReader: dbQueue, consent: [.allowed])
        let found = try repository.findOneToOne(with: Self.agentInbox, excluding: nil)
        #expect(found == nil)
    }

    @Test("one-way latch: extraction reading false must not un-mark a live DM")
    func latchKeepsClassification() {
        let existing = makeConversation(id: "dm-1", isAgentDm: true)
        let incoming = makeConversation(id: "dm-1", isAgentDm: false)
        let saved = ConversationWriter.applyingAgentDmLatch(incoming: incoming, existing: existing, memberCount: 2)
        #expect(saved.isAgentDm)
    }

    @Test("latch keeps a DM hidden after the agent leaves (count 1)")
    func latchKeepsAgentLeftDmHidden() {
        let existing = makeConversation(id: "dm-1", isAgentDm: true)
        let incoming = makeConversation(id: "dm-1", isAgentDm: false)
        let saved = ConversationWriter.applyingAgentDmLatch(incoming: incoming, existing: existing, memberCount: 1)
        #expect(saved.isAgentDm)
    }

    @Test("latch releases when the conversation grew beyond two members")
    func latchReleasesForGrownGroup() {
        // A marked conversation that gained members must never be re-marked:
        // the marker is member-writable, so honoring the latch here would let
        // anyone permanently hide an arbitrary group from every client.
        let existing = makeConversation(id: "c1", isAgentDm: true)
        let incoming = makeConversation(id: "c1", isAgentDm: false)
        let saved = ConversationWriter.applyingAgentDmLatch(incoming: incoming, existing: existing, memberCount: 3)
        #expect(!saved.isAgentDm)
    }

    @Test("latch does not invent classification for unmarked rows")
    func latchDoesNotUpgradeUnmarked() {
        let existing = makeConversation(id: "c1", isAgentDm: false)
        let incoming = makeConversation(id: "c1", isAgentDm: false)
        let saved = ConversationWriter.applyingAgentDmLatch(incoming: incoming, existing: existing, memberCount: 2)
        #expect(!saved.isAgentDm)
        let fresh = ConversationWriter.applyingAgentDmLatch(incoming: incoming, existing: nil, memberCount: 2)
        #expect(!fresh.isAgentDm)
    }

    @Test("latch preserves a newly marked row")
    func latchKeepsIncomingTrue() {
        let existing = makeConversation(id: "dm-1", isAgentDm: false)
        let incoming = makeConversation(id: "dm-1", isAgentDm: true)
        let saved = ConversationWriter.applyingAgentDmLatch(incoming: incoming, existing: existing, memberCount: 2)
        #expect(saved.isAgentDm)
    }
}
