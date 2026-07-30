@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for the denormalized `conversation.lastMessageId` /
/// `lastAgentJoinRequestId` pointers and the `conversation_pointer_*`
/// triggers that maintain them (see
/// `SharedDatabaseMigrator.addConversationLastMessagePointers`). These pin
/// the write-time invariant the conversation-list CTEs now rely on: after
/// any sequence of message writes - inserts, deletes, publish-time id
/// rewrites, metadata rewrites, and conversation row replacement - each
/// pointer equals a fresh recompute of "newest eligible message".
@Suite("Conversation Last Message Pointer Tests", .serialized)
struct ConversationLastMessagePointerTests {
    private static let currentInboxId: String = "inbox-current"
    private static let otherInboxId: String = "inbox-other"

    private static let excludedContentTypesSQL: String = """
        ('update', 'assistantJoinRequest', 'connectionGrantRequest', \
        'connectionInvocation', 'connectionInvocationResult', 'connectionPayload')
        """

    private static func seedInbox(db: Database) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBMember(inboxId: otherInboxId).save(db, onConflict: .ignore)
        try DBInbox(
            inboxId: currentInboxId,
            clientId: "client-current",
            createdAt: Date()
        ).save(db, onConflict: .ignore)
    }

    private static func makeConversation(id: String, createdAt: Date) -> DBConversation {
        DBConversation(
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
        )
    }

    private static func seedConversation(db: Database, id: String, createdAt: Date = Date()) throws {
        try seedInbox(db: db)
        try makeConversation(id: id, createdAt: createdAt).insert(db)
    }

    @discardableResult
    private static func seedMessage(
        db: Database,
        conversationId: String,
        id: String,
        dateNs: Int64,
        contentType: MessageContentType = .text,
        text: String? = "body"
    ) throws -> String {
        try DBMessage(
            id: id,
            clientMessageId: id,
            conversationId: conversationId,
            senderId: otherInboxId,
            dateNs: dateNs,
            date: Date(timeIntervalSince1970: TimeInterval(dateNs) / 1_000_000_000),
            sortId: dateNs,
            status: .published,
            messageType: .original,
            contentType: contentType,
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

    private static func pointers(_ db: Database, conversationId: String) throws -> (last: String?, joinRequest: String?) {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT lastMessageId, lastAgentJoinRequestId FROM conversation WHERE id = ?",
            arguments: [conversationId]
        )
        return (row?["lastMessageId"], row?["lastAgentJoinRequestId"])
    }

    /// Recomputes both pointers from scratch and compares against the stored
    /// columns for every conversation - the invariant the triggers maintain.
    private static func expectPointersMatchRecompute(_ db: Database) throws {
        let mismatches = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id FROM conversation c
                WHERE c.lastMessageId IS NOT (
                    SELECT id FROM message
                    WHERE conversationId = c.id
                        AND contentType NOT IN \(excludedContentTypesSQL)
                    ORDER BY dateNs DESC LIMIT 1
                )
                OR c.lastAgentJoinRequestId IS NOT (
                    SELECT id FROM message
                    WHERE conversationId = c.id AND contentType = 'assistantJoinRequest'
                    ORDER BY dateNs DESC LIMIT 1
                )
                """
        )
        #expect(mismatches.isEmpty)
    }

    // MARK: - Tests

    @Test("Inserts move the pointer only for newer eligible messages")
    func insertsMaintainPointer() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1")
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m1", dateNs: 100)
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m2", dateNs: 200)
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m-update", dateNs: 300, contentType: .update, text: nil)
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m-old", dateNs: 50)
            let pointers = try Self.pointers(db, conversationId: "convo-1")
            #expect(pointers.last == "m2")
            #expect(pointers.joinRequest == nil)
            try Self.expectPointersMatchRecompute(db)
        }
    }

    @Test("Tied dateNs goes to the latest insert")
    func tieGoesToLatestInsert() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1")
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m-tie-1", dateNs: 500)
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m-tie-2", dateNs: 500)
            let pointers = try Self.pointers(db, conversationId: "convo-1")
            #expect(pointers.last == "m-tie-2")
        }
    }

    @Test("Deleting the pointed message recomputes; deleting the rest clears")
    func deleteRecomputes() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1")
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m1", dateNs: 100)
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m2", dateNs: 200)
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m-update", dateNs: 300, contentType: .update, text: nil)

            try db.execute(sql: "DELETE FROM message WHERE id = 'm2'")
            #expect(try Self.pointers(db, conversationId: "convo-1").last == "m1")

            try db.execute(sql: "DELETE FROM message WHERE id = 'm1'")
            #expect(try Self.pointers(db, conversationId: "convo-1").last == nil)
            try Self.expectPointersMatchRecompute(db)
        }
    }

    @Test("Publish-time id rewrite carries both pointers along")
    func publishIdRewriteFollowsPointer() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1")
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "client-m1", dateNs: 100)
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "client-j1", dateNs: 200,
                contentType: .assistantJoinRequest, text: AgentJoinStatus.pending.rawValue
            )

            // The same raw-SQL shape OutgoingMessageWriter uses after publish.
            try db.execute(sql: "UPDATE message SET id = ? WHERE id = ?", arguments: ["xmtp-m1", "client-m1"])
            try db.execute(sql: "UPDATE message SET id = ? WHERE id = ?", arguments: ["xmtp-j1", "client-j1"])

            let pointers = try Self.pointers(db, conversationId: "convo-1")
            #expect(pointers.last == "xmtp-m1")
            #expect(pointers.joinRequest == "xmtp-j1")
            try Self.expectPointersMatchRecompute(db)
        }
    }

    @Test("contentType and dateNs rewrites recompute the pointer")
    func metaRewriteRecomputes() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1")
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m1", dateNs: 100)
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m2", dateNs: 200)

            // The pointed message stops being preview-eligible.
            try db.execute(sql: "UPDATE message SET contentType = 'update' WHERE id = 'm2'")
            #expect(try Self.pointers(db, conversationId: "convo-1").last == "m1")

            // It becomes eligible again and is still the newest.
            try db.execute(sql: "UPDATE message SET contentType = 'text' WHERE id = 'm2'")
            #expect(try Self.pointers(db, conversationId: "convo-1").last == "m2")

            // An older message is re-stamped past the pointed one.
            try db.execute(sql: "UPDATE message SET dateNs = 300 WHERE id = 'm1'")
            #expect(try Self.pointers(db, conversationId: "convo-1").last == "m1")
            try Self.expectPointersMatchRecompute(db)
        }
    }

    @Test("Replacing the conversation row cascades its messages and clears pointers")
    func conversationReplaceCascades() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1")
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m1", dateNs: 100)

            // The same shape as ConversationWriter's replace-by-inviteTag save:
            // REPLACE deletes the old row, the message cascade goes with it,
            // and the re-inserted row correctly starts with NULL pointers.
            try Self.makeConversation(id: "convo-1", createdAt: Date()).insert(db, onConflict: .replace)

            let remaining = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE conversationId = 'convo-1'")
            #expect(remaining == 0)
            let pointers = try Self.pointers(db, conversationId: "convo-1")
            #expect(pointers.last == nil)
            #expect(pointers.joinRequest == nil)
            try Self.expectPointersMatchRecompute(db)
        }
    }

    @Test("Message REPLACE by clientMessageId repoints or repairs the pointer")
    func messageReplaceHealsPointer() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1")
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m1", dateNs: 100)
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m2", dateNs: 200)

            // A stream echo replacing the optimistic row via the
            // clientMessageId unique-on-conflict-replace: the old row is
            // deleted without firing delete triggers, and the insert trigger
            // repoints to the replacement.
            try DBMessage(
                id: "m2-real", clientMessageId: "m2", conversationId: "convo-1",
                senderId: Self.otherInboxId, dateNs: 200, date: Date(),
                sortId: 200, status: .published, messageType: .original,
                contentType: .text, text: "body", emoji: nil, invite: nil,
                linkPreview: nil, sourceMessageId: nil, attachmentUrls: [], update: nil
            ).insert(db)
            #expect(try Self.pointers(db, conversationId: "convo-1").last == "m2-real")

            // A replacement that is not preview-eligible cannot take the
            // pointer itself; the dangling-repair trigger recomputes instead.
            try DBMessage(
                id: "m2-morphed", clientMessageId: "m2", conversationId: "convo-1",
                senderId: Self.otherInboxId, dateNs: 200, date: Date(),
                sortId: 200, status: .published, messageType: .original,
                contentType: .update, text: nil, emoji: nil, invite: nil,
                linkPreview: nil, sourceMessageId: nil, attachmentUrls: [], update: nil
            ).insert(db)
            #expect(try Self.pointers(db, conversationId: "convo-1").last == "m1")
            try Self.expectPointersMatchRecompute(db)
        }
    }

    @Test("Join-request pointer recomputes independently on delete")
    func joinRequestPointerRecomputesOnDelete() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-1")
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m1", dateNs: 100)
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "j1", dateNs: 200,
                contentType: .assistantJoinRequest, text: AgentJoinStatus.failed.rawValue
            )
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "j2", dateNs: 300,
                contentType: .assistantJoinRequest, text: AgentJoinStatus.pending.rawValue
            )

            try db.execute(sql: "DELETE FROM message WHERE id = 'j2'")
            let pointers = try Self.pointers(db, conversationId: "convo-1")
            #expect(pointers.joinRequest == "j1")
            #expect(pointers.last == "m1")
            try Self.expectPointersMatchRecompute(db)
        }
    }

    @Test("Migration backfills pointers for rows that predate it")
    func backfillPopulatesPreMigrationRows() throws {
        let database = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(
            database: database,
            upTo: "addProfilePublishJobProfileUpdatedAt"
        )

        try database.write { db in
            try Self.seedConversation(db: db, id: "convo-1")
            try Self.seedConversation(db: db, id: "convo-empty")
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m1", dateNs: 100)
            try Self.seedMessage(db: db, conversationId: "convo-1", id: "m-update", dateNs: 300, contentType: .update, text: nil)
            try Self.seedMessage(
                db: db, conversationId: "convo-1", id: "j1", dateNs: 200,
                contentType: .assistantJoinRequest, text: AgentJoinStatus.pending.rawValue
            )
        }

        try SharedDatabaseMigrator.shared.migrate(database: database)

        try database.read { db in
            let pointers = try Self.pointers(db, conversationId: "convo-1")
            #expect(pointers.last == "m1")
            #expect(pointers.joinRequest == "j1")
            let empty = try Self.pointers(db, conversationId: "convo-empty")
            #expect(empty.last == nil)
            #expect(empty.joinRequest == nil)
            try Self.expectPointersMatchRecompute(db)
        }
    }

    @Test("Pointer matches recompute across a mixed write sequence")
    func pointerMatchesRecomputeInvariant() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-a")
            try Self.seedConversation(db: db, id: "convo-b")

            for step in 0..<40 {
                let conversationId = step.isMultiple(of: 2) ? "convo-a" : "convo-b"
                let contentType: MessageContentType = switch step % 5 {
                case 0: .update
                case 1: .assistantJoinRequest
                default: .text
                }
                let text: String? = contentType == .assistantJoinRequest ? AgentJoinStatus.pending.rawValue : "body"
                try Self.seedMessage(
                    db: db,
                    conversationId: conversationId,
                    id: "m\(step)",
                    dateNs: Int64((step * 37) % 900),
                    contentType: contentType,
                    text: text
                )
                if step.isMultiple(of: 7) {
                    try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: ["m\(max(0, step - 3))"])
                }
                if step.isMultiple(of: 11) {
                    try db.execute(sql: "UPDATE message SET id = ? WHERE id = ?", arguments: ["m\(step)-published", "m\(step)"])
                }
            }

            try Self.expectPointersMatchRecompute(db)
        }
    }
}
