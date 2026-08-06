@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for desktop-mode human DMs: the live (unlatched) classification
/// predicate, the fact that human DMs stay in the conversations list (unlike
/// agent DMs, which are folded away), and the `findOneToOne` preference for a
/// marked DM over a newer unmarked 2-member group (the just-forked case).
@Suite("Human DM behaviors", .serialized)
struct HumanDmTests {
    private static let selfInbox = "self-inbox"
    private static let peerInbox = "human-peer"

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

    private func seedConversation(
        _ db: Database,
        id: String,
        isHumanDm: Bool,
        createdAt: Date,
        otherInboxIds: [String] = [HumanDmTests.peerInbox]
    ) throws {
        try DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "tag-\(id)",
            creatorId: Self.selfInbox,
            kind: .group,
            consent: .allowed,
            createdAt: createdAt,
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
            isHumanDm: isHumanDm
        ).insert(db)
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
        for otherInboxId in otherInboxIds {
            try seedMember(db, conversationId: id, inboxId: otherInboxId)
        }
    }

    // MARK: - resolveHumanDm truth table (live, no latch)

    @Test("classified as a DM: marker + exactly two members + no verified agent")
    func classifiesMarkedTwoMemberNoAgent() {
        #expect(ConversationWriter.resolveHumanDm(hasMarker: true, memberCount: 2, hasVerifiedAgentMember: false))
    }

    @Test("a third member demotes a marked DM to a group (no latch)")
    func thirdMemberDemotes() {
        #expect(!ConversationWriter.resolveHumanDm(hasMarker: true, memberCount: 3, hasVerifiedAgentMember: false))
    }

    @Test("a verified agent member demotes a marked DM to a group")
    func agentMemberDemotes() {
        #expect(!ConversationWriter.resolveHumanDm(hasMarker: true, memberCount: 2, hasVerifiedAgentMember: true))
    }

    @Test("no marker is never a DM regardless of shape")
    func unmarkedNeverDm() {
        #expect(!ConversationWriter.resolveHumanDm(hasMarker: false, memberCount: 2, hasVerifiedAgentMember: false))
    }

    @Test("re-classifies back to a DM when membership shrinks to two again")
    func reClassifiesOnShrink() {
        // The marker persists in appData and is re-read on every store, so the
        // predicate is a pure function of the current shape: 2 -> 3 demotes,
        // 3 -> 2 re-promotes.
        #expect(!ConversationWriter.resolveHumanDm(hasMarker: true, memberCount: 3, hasVerifiedAgentMember: false))
        #expect(ConversationWriter.resolveHumanDm(hasMarker: true, memberCount: 2, hasVerifiedAgentMember: false))
    }

    // MARK: - List inclusion

    @Test("human DMs remain in the conversations list (unlike agent DMs)")
    func humanDmStaysInList() throws {
        let dbQueue = try makeDatabase()
        let base = Date()
        try dbQueue.write { db in
            try seedInbox(db)
            try seedConversation(db, id: "group-1", isHumanDm: false, createdAt: base)
            try seedConversation(db, id: "human-dm", isHumanDm: true, createdAt: base.addingTimeInterval(60))
        }
        let repository = ConversationsRepository(dbReader: dbQueue, consent: [.allowed])
        let listed = try repository.fetchAll().map(\.id)
        #expect(listed.contains("group-1"))
        #expect(listed.contains("human-dm"))
    }

    // MARK: - findOneToOne preference

    @Test("findOneToOne prefers the marked DM over a newer unmarked 2-member group")
    func findOneToOnePrefersMarkedDm() throws {
        let dbQueue = try makeDatabase()
        let base = Date()
        try dbQueue.write { db in
            try seedInbox(db)
            // Marked DM created earlier; an unmarked fork with the same peer
            // created later (more recent, so it sorts first by recency).
            try seedConversation(db, id: "human-dm", isHumanDm: true, createdAt: base)
            try seedConversation(db, id: "fork-group", isHumanDm: false, createdAt: base.addingTimeInterval(60))
        }
        let repository = ConversationsRepository(dbReader: dbQueue, consent: [.allowed])
        let found = try repository.findOneToOne(with: Self.peerInbox, excluding: nil)
        #expect(found?.id == "human-dm")
        #expect(found?.isHumanDm == true)
    }

    @Test("findOneToOne falls back to the only match when none is marked")
    func findOneToOneFallsBackToUnmarked() throws {
        let dbQueue = try makeDatabase()
        let base = Date()
        try dbQueue.write { db in
            try seedInbox(db)
            try seedConversation(db, id: "plain-1to1", isHumanDm: false, createdAt: base)
        }
        let repository = ConversationsRepository(dbReader: dbQueue, consent: [.allowed])
        let found = try repository.findOneToOne(with: Self.peerInbox, excluding: nil)
        #expect(found?.id == "plain-1to1")
    }
}
