import Foundation
import GRDB
import Testing
@testable import ConvosCore

/// Covers the agent-DM fold that gives each list row its DM lane: which DM a
/// row resolves to, how the fold re-sorts by the newer of the two lanes, and
/// that the lookup costs one query per read rather than one per row.
@Suite("Agent DM Fold Tests", .serialized)
struct AgentDmFoldTests {
    private static let currentInboxId: String = "inbox-current"

    /// Counts the DM lookups a read performs. Every such lookup asserts its
    /// membership shape through `conversation_members AS cm_...` subqueries,
    /// so counting statements that mention one distinguishes "one query for
    /// the page" from "one query per row" regardless of the aliases used.
    private final class QueryCounter: @unchecked Sendable {
        private let lock: NSLock = .init()
        private var value: Int = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    private static func tracedQueue(_ counter: QueryCounter) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { event in
                guard "\(event)".contains("conversation_members AS cm_") else { return }
                counter.increment()
            }
        }
        let queue = try DatabaseQueue(configuration: configuration)
        try SharedDatabaseMigrator.shared.migrate(database: queue)
        return queue
    }

    private static func seedBase(_ db: Database) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBInbox(inboxId: currentInboxId, clientId: "client-current").save(db, onConflict: .ignore)
    }

    private static func seedAgent(_ db: Database, inboxId: String, name: String) throws {
        try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        try DBProfile(
            inboxId: inboxId,
            name: name,
            memberKind: .verifiedConvos,
            profileSource: .profileUpdate,
            updatedAt: Date()
        ).save(db)
    }

    /// A conversation plus the local state every list read joins on. `memberInboxIds`
    /// excludes the current user, who is always a member.
    private static func seedConversation(
        _ db: Database,
        id: String,
        createdAt: Date,
        isAgentDm: Bool = false,
        isUnread: Bool = false,
        memberInboxIds: [String] = []
    ) throws {
        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: currentInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: createdAt,
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
        ).insert(db)

        try ConversationLocalState(
            conversationId: id,
            isPinned: false,
            isUnread: isUnread,
            isUnreadUpdatedAt: Date(),
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            hasHadOtherMembers: false,
            hasSharedInvite: false
        ).insert(db)

        try DBConversationMember(
            conversationId: id,
            inboxId: currentInboxId,
            role: .superAdmin,
            consent: .allowed,
            createdAt: createdAt,
            invitedByInboxId: nil
        ).insert(db)
        for memberInboxId in memberInboxIds {
            try DBConversationMember(
                conversationId: id,
                inboxId: memberInboxId,
                role: .member,
                consent: .allowed,
                createdAt: createdAt,
                invitedByInboxId: nil
            ).insert(db)
        }
    }

    @discardableResult
    private static func seedMessage(
        _ db: Database,
        conversationId: String,
        id: String,
        senderId: String,
        date: Date,
        text: String
    ) throws -> String {
        let dateNs = Int64(date.timeIntervalSince1970 * 1_000_000_000)
        try DBMessage(
            id: id,
            clientMessageId: id,
            conversationId: conversationId,
            senderId: senderId,
            dateNs: dateNs,
            date: date,
            sortId: dateNs,
            status: .published,
            messageType: .original,
            contentType: .text,
            text: text,
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            update: nil
        ).insert(db)
        return id
    }

    private func repo(_ queue: DatabaseQueue) -> ConversationsRepository {
        ConversationsRepository(dbReader: queue, consent: [.allowed, .unknown])
    }

    @Test("A group with a verified agent folds in that agent's DM")
    func foldsAgentDmIntoGroup() throws {
        let counter = QueryCounter()
        let queue = try Self.tracedQueue(counter)
        try queue.write { db in
            try Self.seedBase(db)
            try Self.seedAgent(db, inboxId: "agent-1", name: "Ada")
            try Self.seedConversation(
                db,
                id: "group-1",
                createdAt: Date(timeIntervalSince1970: 1_000),
                memberInboxIds: ["agent-1"]
            )
            try Self.seedConversation(
                db,
                id: "dm-1",
                createdAt: Date(timeIntervalSince1970: 1_000),
                isAgentDm: true,
                isUnread: true,
                memberInboxIds: ["agent-1"]
            )
            try Self.seedMessage(
                db,
                conversationId: "dm-1",
                id: "dm-msg-1",
                senderId: "agent-1",
                date: Date(timeIntervalSince1970: 2_000),
                text: "from the agent"
            )
        }

        let conversations = try repo(queue).fetchAll()

        #expect(conversations.count == 1)
        let agentDm = try #require(conversations.first?.agentDm)
        #expect(agentDm.inboxId == "agent-1")
        #expect(agentDm.displayName == "Ada")
        #expect(agentDm.isUnread)
        #expect(agentDm.lastMessage?.text == "from the agent")
    }

    @Test("A group with no verified agent folds nothing and runs no DM query")
    func skipsGroupsWithoutAgents() throws {
        let counter = QueryCounter()
        let queue = try Self.tracedQueue(counter)
        try queue.write { db in
            try Self.seedBase(db)
            try Self.seedConversation(
                db,
                id: "group-1",
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
        }

        let conversations = try repo(queue).fetchAll()

        #expect(conversations.count == 1)
        #expect(conversations.first?.agentDm == nil)
        // The fast path matters: a list of agent-free rows should not pay for
        // the lookup at all.
        #expect(counter.count == 0)
    }

    @Test("Many rows sharing one agent all fold from a single DM query")
    func foldsManyRowsInOneQuery() throws {
        let counter = QueryCounter()
        let queue = try Self.tracedQueue(counter)
        let groupCount = 25
        try queue.write { db in
            try Self.seedBase(db)
            try Self.seedAgent(db, inboxId: "agent-1", name: "Ada")
            for i in 0..<groupCount {
                try Self.seedConversation(
                    db,
                    id: "group-\(i)",
                    createdAt: Date(timeIntervalSince1970: 1_000 + Double(i)),
                    memberInboxIds: ["agent-1"]
                )
            }
            try Self.seedConversation(
                db,
                id: "dm-1",
                createdAt: Date(timeIntervalSince1970: 1_000),
                isAgentDm: true,
                memberInboxIds: ["agent-1"]
            )
        }

        let conversations = try repo(queue).fetchAll()

        #expect(conversations.count == groupCount)
        #expect(conversations.allSatisfy { $0.agentDm?.inboxId == "agent-1" })
        // The regression this guards: the fold used to issue one DM lookup per
        // row, so this count tracked `groupCount` instead of staying flat.
        #expect(counter.count == 1)
    }

    @Test("Each row resolves its own agent when several agents are on the page")
    func foldsPerAgent() throws {
        let counter = QueryCounter()
        let queue = try Self.tracedQueue(counter)
        try queue.write { db in
            try Self.seedBase(db)
            try Self.seedAgent(db, inboxId: "agent-1", name: "Ada")
            try Self.seedAgent(db, inboxId: "agent-2", name: "Grace")
            try Self.seedConversation(
                db,
                id: "group-1",
                createdAt: Date(timeIntervalSince1970: 1_000),
                memberInboxIds: ["agent-1"]
            )
            try Self.seedConversation(
                db,
                id: "group-2",
                createdAt: Date(timeIntervalSince1970: 1_100),
                memberInboxIds: ["agent-2"]
            )
            try Self.seedConversation(
                db,
                id: "dm-1",
                createdAt: Date(timeIntervalSince1970: 1_000),
                isAgentDm: true,
                memberInboxIds: ["agent-1"]
            )
            try Self.seedMessage(
                db,
                conversationId: "dm-1",
                id: "dm-msg-1",
                senderId: "agent-1",
                date: Date(timeIntervalSince1970: 2_000),
                text: "from Ada"
            )
            try Self.seedConversation(
                db,
                id: "dm-2",
                createdAt: Date(timeIntervalSince1970: 1_100),
                isAgentDm: true,
                memberInboxIds: ["agent-2"]
            )
            try Self.seedMessage(
                db,
                conversationId: "dm-2",
                id: "dm-msg-2",
                senderId: "agent-2",
                date: Date(timeIntervalSince1970: 2_100),
                text: "from Grace"
            )
        }

        let conversations = try repo(queue).fetchAll()
        let byId = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

        #expect(byId["group-1"]?.agentDm?.lastMessage?.text == "from Ada")
        #expect(byId["group-2"]?.agentDm?.lastMessage?.text == "from Grace")
        #expect(counter.count == 1)
    }

    @Test("An agent with several DMs folds in its most recently active one")
    func foldsMostRecentDmPerAgent() throws {
        let counter = QueryCounter()
        let queue = try Self.tracedQueue(counter)
        try queue.write { db in
            try Self.seedBase(db)
            try Self.seedAgent(db, inboxId: "agent-1", name: "Ada")
            try Self.seedConversation(
                db,
                id: "group-1",
                createdAt: Date(timeIntervalSince1970: 1_000),
                memberInboxIds: ["agent-1"]
            )
            try Self.seedConversation(
                db,
                id: "dm-old",
                createdAt: Date(timeIntervalSince1970: 1_000),
                isAgentDm: true,
                memberInboxIds: ["agent-1"]
            )
            try Self.seedMessage(
                db,
                conversationId: "dm-old",
                id: "dm-msg-old",
                senderId: "agent-1",
                date: Date(timeIntervalSince1970: 2_000),
                text: "older lane"
            )
            try Self.seedConversation(
                db,
                id: "dm-new",
                createdAt: Date(timeIntervalSince1970: 1_100),
                isAgentDm: true,
                memberInboxIds: ["agent-1"]
            )
            try Self.seedMessage(
                db,
                conversationId: "dm-new",
                id: "dm-msg-new",
                senderId: "agent-1",
                date: Date(timeIntervalSince1970: 3_000),
                text: "newer lane"
            )
        }

        let conversations = try repo(queue).fetchAll()

        #expect(conversations.first?.agentDm?.lastMessage?.text == "newer lane")
    }

    @Test("A DM reply floats its origin row above a more recently messaged group")
    func resortsByNewerLane() throws {
        let counter = QueryCounter()
        let queue = try Self.tracedQueue(counter)
        try queue.write { db in
            try Self.seedBase(db)
            try Self.seedAgent(db, inboxId: "agent-1", name: "Ada")
            // Quiet on its own lane, but its DM just replied.
            try Self.seedConversation(
                db,
                id: "group-quiet",
                createdAt: Date(timeIntervalSince1970: 1_000),
                memberInboxIds: ["agent-1"]
            )
            try Self.seedMessage(
                db,
                conversationId: "group-quiet",
                id: "quiet-msg",
                senderId: Self.currentInboxId,
                date: Date(timeIntervalSince1970: 2_000),
                text: "old group message"
            )
            // Newer on its own lane, so it wins the SQL ordering.
            try Self.seedConversation(
                db,
                id: "group-busy",
                createdAt: Date(timeIntervalSince1970: 1_100)
            )
            try Self.seedMessage(
                db,
                conversationId: "group-busy",
                id: "busy-msg",
                senderId: Self.currentInboxId,
                date: Date(timeIntervalSince1970: 3_000),
                text: "newer group message"
            )
            try Self.seedConversation(
                db,
                id: "dm-1",
                createdAt: Date(timeIntervalSince1970: 1_000),
                isAgentDm: true,
                memberInboxIds: ["agent-1"]
            )
            try Self.seedMessage(
                db,
                conversationId: "dm-1",
                id: "dm-msg-1",
                senderId: "agent-1",
                date: Date(timeIntervalSince1970: 4_000),
                text: "freshest of all"
            )
        }

        let conversations = try repo(queue).fetchAll()

        #expect(conversations.map(\.id) == ["group-quiet", "group-busy"])
    }
}
