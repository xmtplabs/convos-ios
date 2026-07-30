@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for `lastMessageWithSourceCTE` and `latestAgentJoinRequestCTE`,
/// now resolved through the denormalized `conversation.lastMessageId` /
/// `lastAgentJoinRequestId` pointers. These pin the observable semantics
/// every implementation must preserve: newest eligible message wins,
/// excluded content types never surface as previews, reply/reaction
/// previews carry the source message text, conversations without eligible
/// messages fall back to `createdAt` ordering, and the newest agent join
/// request drives `agentJoinStatus`. Trigger-level behavior is covered in
/// `ConversationLastMessagePointerTests`.
@Suite("Conversation Last Message CTE Tests", .serialized)
struct ConversationLastMessageCTETests {
    private static let currentInboxId: String = "inbox-current"
    private static let otherInboxId: String = "inbox-other"

    private static func seedInbox(db: Database) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBInbox(
            inboxId: currentInboxId,
            clientId: "client-current",
            createdAt: Date()
        ).save(db, onConflict: .ignore)
    }

    /// Seeds a two-member conversation (current user + other) with every
    /// row `detailedConversationQuery` requires. Two members keeps
    /// `shouldShowSenderName` false so text previews are the raw body.
    private static func seedConversation(
        db: Database,
        id: String,
        createdAt: Date
    ) throws {
        try seedInbox(db: db)
        try DBMember(inboxId: otherInboxId).save(db, onConflict: .ignore)

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
            hasHadVerifiedAgent: false
        ).insert(db)

        try ConversationLocalState(
            conversationId: id,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: createdAt,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false,
            leftHostedInviteSession: false,
            wasRemoved: false,
            hasHadOtherMembers: false,
            hasSharedInvite: false
        ).insert(db)

        for (index, inboxId) in [currentInboxId, otherInboxId].enumerated() {
            let role: MemberRole = index == 0 ? .superAdmin : .member
            try DBConversationMember(
                conversationId: id,
                inboxId: inboxId,
                role: role,
                consent: .allowed,
                createdAt: createdAt,
                invitedByInboxId: nil
            ).insert(db)
            try DBMemberProfile(
                conversationId: id,
                inboxId: inboxId,
                name: inboxId,
                avatar: nil
            ).insert(db, onConflict: .ignore)
        }
    }

    @discardableResult
    private static func seedMessage(
        db: Database,
        conversationId: String,
        id: String,
        dateNs: Int64,
        date: Date,
        messageType: DBMessageType = .original,
        contentType: MessageContentType = .text,
        text: String? = nil,
        emoji: String? = nil,
        sourceMessageId: String? = nil
    ) throws -> String {
        try DBMessage(
            id: id,
            clientMessageId: id,
            conversationId: conversationId,
            senderId: otherInboxId,
            dateNs: dateNs,
            date: date,
            sortId: dateNs,
            status: .published,
            messageType: messageType,
            contentType: contentType,
            text: text,
            emoji: emoji,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: sourceMessageId,
            attachmentUrls: [],
            update: nil
        ).insert(db)
        return id
    }

    private static func fetchAll(_ dbManager: any DatabaseManagerProtocol) throws -> [Conversation] {
        let repo = ConversationsRepository(dbReader: dbManager.dbReader, consent: [.allowed])
        return try repo.fetchAll()
    }

    // MARK: - Tests

    @Test("Newest eligible message wins over newer excluded content types")
    func newestEligibleMessageWins() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let base = Date()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1", createdAt: base)
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "m-old",
                dateNs: 1_000, date: base, text: "older text"
            )
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "m-latest-eligible",
                dateNs: 2_000, date: base.addingTimeInterval(1), text: "latest eligible text"
            )
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "m-newer-update",
                dateNs: 3_000, date: base.addingTimeInterval(2), contentType: .update
            )
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "m-newer-invocation",
                dateNs: 4_000, date: base.addingTimeInterval(3),
                contentType: .connectionInvocation, text: "{}"
            )
        }

        let conversations = try Self.fetchAll(dbManager)
        #expect(conversations.count == 1)
        #expect(conversations.first?.lastMessage?.text == "latest eligible text")
    }

    @Test("Each conversation gets its own last message")
    func lastMessagesDoNotLeakAcrossConversations() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let base = Date()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-a", createdAt: base)
            try Self.seedConversation(db: db, id: "convo-b", createdAt: base)
            try Self.seedMessage(
                db: db, conversationId: "convo-a", id: "m-a",
                dateNs: 1_000, date: base, text: "message in a"
            )
            try Self.seedMessage(
                db: db, conversationId: "convo-b", id: "m-b",
                dateNs: 2_000, date: base.addingTimeInterval(1), text: "message in b"
            )
        }

        let conversations = try Self.fetchAll(dbManager)
        let byId = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        #expect(byId["convo-a"]?.lastMessage?.text == "message in a")
        #expect(byId["convo-b"]?.lastMessage?.text == "message in b")
    }

    @Test("Reaction preview joins the source message text")
    func reactionPreviewCarriesSourceText() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let base = Date()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1", createdAt: base)
            let sourceId = try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "m-source",
                dateNs: 1_000, date: base, text: "the original body"
            )
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "m-reaction",
                dateNs: 2_000, date: base.addingTimeInterval(1),
                messageType: .reaction, contentType: .emoji,
                emoji: "🔥", sourceMessageId: sourceId
            )
        }

        let conversations = try Self.fetchAll(dbManager)
        let previewText = conversations.first?.lastMessage?.text ?? ""
        #expect(previewText.contains("🔥"))
        #expect(previewText.contains("the original body"))
    }

    @Test("Conversations without eligible messages order by createdAt and have no preview")
    func orderingFallsBackToCreatedAt() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let base = Date()
        try dbManager.dbWriter.write { db in
            // Oldest createdAt, but the newest message overall.
            try Self.seedConversation(db: db, id: "convo-active", createdAt: base)
            // Newer createdAt than convo-active, older message activity.
            try Self.seedConversation(
                db: db, id: "convo-quiet", createdAt: base.addingTimeInterval(10)
            )
            // Newest createdAt, no messages at all.
            try Self.seedConversation(
                db: db, id: "convo-empty", createdAt: base.addingTimeInterval(20)
            )
            try Self.seedMessage(
                db: db, conversationId: "convo-quiet", id: "m-quiet",
                dateNs: 1_000, date: base.addingTimeInterval(15), text: "quiet"
            )
            try Self.seedMessage(
                db: db, conversationId: "convo-active", id: "m-active",
                dateNs: 2_000, date: base.addingTimeInterval(30), text: "active"
            )
        }

        let conversations = try Self.fetchAll(dbManager)
        #expect(conversations.map(\.id) == ["convo-active", "convo-empty", "convo-quiet"])
        #expect(conversations.first { $0.id == "convo-empty" }?.lastMessage == nil)
    }

    @Test("Tied dateNs still yields a single conversation row")
    func tiedDateNsCollapsesToOneRow() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let base = Date()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1", createdAt: base)
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "m-tie-1",
                dateNs: 5_000, date: base, text: "tied one"
            )
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "m-tie-2",
                dateNs: 5_000, date: base, text: "tied two"
            )
        }

        let conversations = try Self.fetchAll(dbManager)
        #expect(conversations.count == 1)
        let previewText = conversations.first?.lastMessage?.text
        #expect(previewText == "tied one" || previewText == "tied two")
    }

    @Test("Newest agent join request drives agentJoinStatus; requests stay out of previews")
    func newestAgentJoinRequestWins() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let base = Date()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1", createdAt: base)
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "m-text",
                dateNs: 1_000, date: base.addingTimeInterval(-5), text: "visible preview"
            )
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "m-join-failed",
                dateNs: 2_000, date: base.addingTimeInterval(-4),
                contentType: .assistantJoinRequest, text: AgentJoinStatus.failed.rawValue
            )
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "m-join-pending",
                dateNs: 3_000, date: base,
                contentType: .assistantJoinRequest, text: AgentJoinStatus.pending.rawValue
            )
        }

        let conversations = try Self.fetchAll(dbManager)
        #expect(conversations.first?.agentJoinStatus == .pending)
        #expect(conversations.first?.lastMessage?.text == "visible preview")
    }
}
