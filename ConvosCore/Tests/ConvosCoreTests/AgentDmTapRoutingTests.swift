import Foundation
import GRDB
import Testing
@testable import ConvosCore

/// Covers the DM -> parent-group routing a tapped DM notification relies on:
/// `DBAgentDmOrigin` persistence and `ConversationsRepository.agentDmTapRouting`.
@Suite("Agent DM Tap Routing Tests", .serialized)
struct AgentDmTapRoutingTests {
    private static let currentInboxId: String = "inbox-current"
    private static let agentInboxId: String = "inbox-agent"
    private static let parentId: String = "parent-group"
    private static let dmId: String = "dm-conversation"

    private static func makeConversation(id: String, isAgentDm: Bool) -> DBConversation {
        DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
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
            hasHadVerifiedAgent: false,
            isAgentDm: isAgentDm
        )
    }

    /// Seeds a parent group and a 2-member agent DM (current user + a verified
    /// agent). `withOrigin` controls whether the DM -> parent link is recorded;
    /// `agentVerified` controls whether the agent member reads as verified.
    private static func seed(
        _ db: Database,
        withOrigin: Bool = true,
        agentVerified: Bool = true
    ) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBMember(inboxId: agentInboxId).save(db, onConflict: .ignore)
        try DBInbox(inboxId: currentInboxId, clientId: "client-current").save(db, onConflict: .ignore)
        try DBProfile(
            inboxId: agentInboxId,
            name: "Agent",
            memberKind: agentVerified ? .verifiedConvos : .agent,
            profileSource: .profileUpdate,
            updatedAt: Date()
        ).save(db)

        try makeConversation(id: parentId, isAgentDm: false).insert(db)
        try makeConversation(id: dmId, isAgentDm: true).insert(db)

        try DBConversationMember(
            conversationId: dmId, inboxId: currentInboxId, role: .superAdmin,
            consent: .allowed, createdAt: Date(), invitedByInboxId: nil
        ).insert(db)
        try DBConversationMember(
            conversationId: dmId, inboxId: agentInboxId, role: .member,
            consent: .allowed, createdAt: Date(), invitedByInboxId: nil
        ).insert(db)

        if withOrigin {
            try DBAgentDmOrigin.record(conversationId: dmId, originConversationId: parentId, in: db)
        }
    }

    private static func migratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: queue)
        return queue
    }

    private func repo(_ queue: DatabaseQueue) -> ConversationsRepository {
        ConversationsRepository(dbReader: queue, consent: [.allowed, .unknown])
    }

    @Test("A DM tap routes to its parent group and the verified agent")
    func routesDmToParentAndAgent() throws {
        let queue = try Self.migratedQueue()
        try queue.write { try Self.seed($0) }

        let routing = try repo(queue).agentDmTapRouting(forConversationId: Self.dmId)

        #expect(routing == AgentDmTapRouting(
            originConversationId: Self.parentId,
            agentInboxId: Self.agentInboxId
        ))
    }

    @Test("A group tap is not agent-DM routing")
    func groupTapReturnsNil() throws {
        let queue = try Self.migratedQueue()
        try queue.write { try Self.seed($0) }

        #expect(try repo(queue).agentDmTapRouting(forConversationId: Self.parentId) == nil)
    }

    @Test("A DM without a recorded parent link does not route")
    func dmWithoutOriginReturnsNil() throws {
        let queue = try Self.migratedQueue()
        try queue.write { try Self.seed($0, withOrigin: false) }

        #expect(try repo(queue).agentDmTapRouting(forConversationId: Self.dmId) == nil)
    }

    @Test("A DM whose only other member is unverified does not route")
    func dmWithoutVerifiedAgentReturnsNil() throws {
        let queue = try Self.migratedQueue()
        try queue.write { try Self.seed($0, agentVerified: false) }

        #expect(try repo(queue).agentDmTapRouting(forConversationId: Self.dmId) == nil)
    }

    @Test("DBAgentDmOrigin records and reads back the parent link; a nil origin is a no-op")
    func originRoundTrip() throws {
        let queue = try Self.migratedQueue()
        try queue.write { db in
            try Self.seed(db, withOrigin: false)

            try DBAgentDmOrigin.record(conversationId: Self.dmId, originConversationId: Self.parentId, in: db)
            #expect(try DBAgentDmOrigin.originConversationId(for: Self.dmId, in: db) == Self.parentId)

            // A marker written without an origin must not clear a good link.
            try DBAgentDmOrigin.record(conversationId: Self.dmId, originConversationId: nil, in: db)
            #expect(try DBAgentDmOrigin.originConversationId(for: Self.dmId, in: db) == Self.parentId)

            #expect(try DBAgentDmOrigin.originConversationId(for: "unknown", in: db) == nil)
        }
    }
}
