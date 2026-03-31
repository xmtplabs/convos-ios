@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("Chronological SortId Tests", .serialized)
struct ChronologicalSortIdTests {
    // MARK: - chronologicalSortId

    @Test("appends to end when message is newest")
    func testAppendsToEndWhenNewest() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-1"

        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: conversationId)
            try insertMessage(db: db, id: "msg-1", conversationId: conversationId, dateNs: 1000, sortId: 1)
            try insertMessage(db: db, id: "msg-2", conversationId: conversationId, dateNs: 2000, sortId: 2)
        }

        let newSortId = try db.dbWriter.write { db in
            try IncomingMessageWriter.chronologicalSortId(
                for: 3000, messageId: "msg-3", conversationId: conversationId, in: db
            )
        }

        #expect(newSortId == 3)
        try verifySortOrder(db: db, conversationId: conversationId, expected: ["msg-1", "msg-2"])
    }

    @Test("inserts at beginning when message is oldest")
    func testInsertsAtBeginningWhenOldest() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-1"

        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: conversationId)
            try insertMessage(db: db, id: "msg-2", conversationId: conversationId, dateNs: 2000, sortId: 1)
            try insertMessage(db: db, id: "msg-3", conversationId: conversationId, dateNs: 3000, sortId: 2)
        }

        let newSortId = try db.dbWriter.write { db in
            try IncomingMessageWriter.chronologicalSortId(
                for: 1000, messageId: "msg-1", conversationId: conversationId, in: db
            )
        }

        #expect(newSortId == 1)
        try verifySortOrder(db: db, conversationId: conversationId, expected: ["msg-2", "msg-3"])

        // Verify existing messages were shifted
        let sortIds = try db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .order(DBMessage.Columns.sortId.asc)
                .fetchAll(db)
                .map { ($0.id, $0.sortId) }
        }
        #expect(sortIds[0].0 == "msg-2")
        #expect(sortIds[0].1 == 2)
        #expect(sortIds[1].0 == "msg-3")
        #expect(sortIds[1].1 == 3)
    }

    @Test("inserts in middle at correct chronological position")
    func testInsertsInMiddle() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-1"

        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: conversationId)
            try insertMessage(db: db, id: "msg-1", conversationId: conversationId, dateNs: 1000, sortId: 1)
            try insertMessage(db: db, id: "msg-3", conversationId: conversationId, dateNs: 3000, sortId: 2)
        }

        let newSortId = try db.dbWriter.write { db in
            try IncomingMessageWriter.chronologicalSortId(
                for: 2000, messageId: "msg-2", conversationId: conversationId, in: db
            )
        }

        #expect(newSortId == 2)

        // msg-3 should have been shifted from 2 to 3
        let sortIds = try db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .order(DBMessage.Columns.sortId.asc)
                .fetchAll(db)
                .map { ($0.id, $0.sortId) }
        }
        #expect(sortIds[0] == ("msg-1", 1))
        #expect(sortIds[1] == ("msg-3", 3))
    }

    @Test("handles same dateNs with id tiebreaker")
    func testSameDateNsWithIdTiebreaker() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-1"

        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: conversationId)
            try insertMessage(db: db, id: "bbb", conversationId: conversationId, dateNs: 1000, sortId: 1)
        }

        // "aaa" < "bbb" lexicographically, so "aaa" should go before "bbb"
        let newSortId = try db.dbWriter.write { db in
            try IncomingMessageWriter.chronologicalSortId(
                for: 1000, messageId: "aaa", conversationId: conversationId, in: db
            )
        }

        #expect(newSortId == 1)

        // "bbb" should have been shifted to 2
        let sortIds = try db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .order(DBMessage.Columns.sortId.asc)
                .fetchAll(db)
                .map { ($0.id, $0.sortId) }
        }
        #expect(sortIds[0] == ("bbb", 2))
    }

    @Test("same dateNs, later id goes after")
    func testSameDateNsLaterIdGoesAfter() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-1"

        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: conversationId)
            try insertMessage(db: db, id: "aaa", conversationId: conversationId, dateNs: 1000, sortId: 1)
        }

        // "zzz" > "aaa" lexicographically, so "zzz" should go after "aaa"
        let newSortId = try db.dbWriter.write { db in
            try IncomingMessageWriter.chronologicalSortId(
                for: 1000, messageId: "zzz", conversationId: conversationId, in: db
            )
        }

        #expect(newSortId == 2)
    }

    @Test("first message in empty conversation gets sortId 1")
    func testFirstMessageGetsSortId1() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-1"

        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: conversationId)
        }

        let newSortId = try db.dbWriter.write { db in
            try IncomingMessageWriter.chronologicalSortId(
                for: 1000, messageId: "msg-1", conversationId: conversationId, in: db
            )
        }

        #expect(newSortId == 1)
    }

    @Test("does not affect messages in other conversations")
    func testIsolatedByConversation() throws {
        let db = MockDatabaseManager.makeTestDatabase()

        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: "conv-1")
            try seedConversation(db: db, conversationId: "conv-2", clientConversationId: "client-conv-2")
            try insertMessage(db: db, id: "c1-msg-1", conversationId: "conv-1", dateNs: 2000, sortId: 1)
            try insertMessage(db: db, id: "c2-msg-1", conversationId: "conv-2", dateNs: 1000, sortId: 1)
            try insertMessage(db: db, id: "c2-msg-2", conversationId: "conv-2", dateNs: 3000, sortId: 2)
        }

        // Insert a message in conv-1 that is oldest — should only shift conv-1 messages
        let newSortId = try db.dbWriter.write { db in
            try IncomingMessageWriter.chronologicalSortId(
                for: 1000, messageId: "c1-msg-0", conversationId: "conv-1", in: db
            )
        }

        #expect(newSortId == 1)

        // conv-2 messages should be unchanged
        let conv2SortIds = try db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == "conv-2")
                .order(DBMessage.Columns.sortId.asc)
                .fetchAll(db)
                .map { ($0.id, $0.sortId) }
        }
        #expect(conv2SortIds[0] == ("c2-msg-1", 1))
        #expect(conv2SortIds[1] == ("c2-msg-2", 2))
    }

    @Test("simulates NSE processing messages out of order")
    func testNSEOutOfOrderProcessing() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-1"

        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: conversationId)
        }

        // NSE receives push for message C (dateNs=3000) first
        try db.dbWriter.write { db in
            let sortId = try IncomingMessageWriter.chronologicalSortId(
                for: 3000, messageId: "msg-c", conversationId: conversationId, in: db
            )
            try insertMessage(db: db, id: "msg-c", conversationId: conversationId, dateNs: 3000, sortId: sortId)
        }

        // Then processes message A (dateNs=1000)
        try db.dbWriter.write { db in
            let sortId = try IncomingMessageWriter.chronologicalSortId(
                for: 1000, messageId: "msg-a", conversationId: conversationId, in: db
            )
            try insertMessage(db: db, id: "msg-a", conversationId: conversationId, dateNs: 1000, sortId: sortId)
        }

        // Then processes message B (dateNs=2000)
        try db.dbWriter.write { db in
            let sortId = try IncomingMessageWriter.chronologicalSortId(
                for: 2000, messageId: "msg-b", conversationId: conversationId, in: db
            )
            try insertMessage(db: db, id: "msg-b", conversationId: conversationId, dateNs: 2000, sortId: sortId)
        }

        // All messages should be in chronological order by sortId
        let messages = try db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .order(DBMessage.Columns.sortId.asc)
                .fetchAll(db)
        }

        #expect(messages.count == 3)
        #expect(messages[0].id == "msg-a")
        #expect(messages[0].sortId == 1)
        #expect(messages[1].id == "msg-b")
        #expect(messages[1].sortId == 2)
        #expect(messages[2].id == "msg-c")
        #expect(messages[2].sortId == 3)
    }

    @Test("simulates NSE and main app racing to store the same message batch")
    func testNSEAndMainAppRace() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-1"

        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: conversationId)
        }

        // Main app streams message A first (dateNs=1000)
        try db.dbWriter.write { db in
            let sortId = try IncomingMessageWriter.chronologicalSortId(
                for: 1000, messageId: "msg-a", conversationId: conversationId, in: db
            )
            try insertMessage(db: db, id: "msg-a", conversationId: conversationId, dateNs: 1000, sortId: sortId)
        }

        // NSE processes message C (dateNs=3000) — the push notification trigger
        try db.dbWriter.write { db in
            let sortId = try IncomingMessageWriter.chronologicalSortId(
                for: 3000, messageId: "msg-c", conversationId: conversationId, in: db
            )
            try insertMessage(db: db, id: "msg-c", conversationId: conversationId, dateNs: 3000, sortId: sortId)
        }

        // Main app streams message B (dateNs=2000) — arrived between A and C
        try db.dbWriter.write { db in
            let sortId = try IncomingMessageWriter.chronologicalSortId(
                for: 2000, messageId: "msg-b", conversationId: conversationId, in: db
            )
            try insertMessage(db: db, id: "msg-b", conversationId: conversationId, dateNs: 2000, sortId: sortId)
        }

        // Verify chronological order
        let messages = try db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .order(DBMessage.Columns.sortId.asc)
                .fetchAll(db)
        }

        #expect(messages.count == 3)
        #expect(messages[0].id == "msg-a")
        #expect(messages[1].id == "msg-b")
        #expect(messages[2].id == "msg-c")

        // Verify sortIds are contiguous
        #expect(messages[0].sortId == 1)
        #expect(messages[1].sortId == 2)
        #expect(messages[2].sortId == 3)
    }

    @Test("multiple insertions at the same position maintain id-based ordering")
    func testMultipleInsertionsSameTimestamp() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-1"

        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: conversationId)
        }

        let ids = ["delta", "bravo", "charlie", "alpha"]
        for id in ids {
            try db.dbWriter.write { db in
                let sortId = try IncomingMessageWriter.chronologicalSortId(
                    for: 1000, messageId: id, conversationId: conversationId, in: db
                )
                try insertMessage(db: db, id: id, conversationId: conversationId, dateNs: 1000, sortId: sortId)
            }
        }

        let messages = try db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .order(DBMessage.Columns.sortId.asc)
                .fetchAll(db)
        }

        #expect(messages.count == 4)
        #expect(messages[0].id == "alpha")
        #expect(messages[1].id == "bravo")
        #expect(messages[2].id == "charlie")
        #expect(messages[3].id == "delta")
    }

    @Test("reactions with nil sortId do not interfere with chronological insertion")
    func testReactionsDoNotInterfere() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-1"

        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: conversationId)
            try insertMessage(db: db, id: "msg-1", conversationId: conversationId, dateNs: 1000, sortId: 1)
            try insertMessage(db: db, id: "msg-3", conversationId: conversationId, dateNs: 3000, sortId: 2)

            // Insert a reaction with nil sortId (as ReactionWriter does)
            try DBMessage(
                id: "reaction-1",
                clientMessageId: "reaction-1",
                conversationId: conversationId,
                senderId: "current-user",
                dateNs: 1500,
                date: Date(timeIntervalSince1970: 0.0000015),
                sortId: nil,
                status: .published,
                messageType: .reaction,
                contentType: .emoji,
                text: nil,
                emoji: "👍",
                invite: nil,
                sourceMessageId: "msg-1",
                attachmentUrls: [],
                update: nil
            ).insert(db)
        }

        // Insert msg-2 between msg-1 and msg-3
        let newSortId = try db.dbWriter.write { db in
            try IncomingMessageWriter.chronologicalSortId(
                for: 2000, messageId: "msg-2", conversationId: conversationId, in: db
            )
        }

        #expect(newSortId == 2)

        // Verify: msg-1 at 1, msg-3 shifted to 3, reaction still nil
        let allMessages = try db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .fetchAll(db)
        }

        let msg1 = allMessages.first(where: { $0.id == "msg-1" })
        let msg3 = allMessages.first(where: { $0.id == "msg-3" })
        let reaction = allMessages.first(where: { $0.id == "reaction-1" })

        #expect(msg1?.sortId == 1)
        #expect(msg3?.sortId == 3)
        #expect(reaction?.sortId == nil)
    }

    // MARK: - Helpers

    private func seedConversation(
        db: Database,
        conversationId: String,
        clientConversationId: String = "client-conv-1"
    ) throws {
        let currentInboxId = "current-user"
        try DBMember(inboxId: currentInboxId).save(db)

        try DBConversation(
            id: conversationId,
            inboxId: currentInboxId,
            clientId: "client-1",
            clientConversationId: clientConversationId,
            inviteTag: "tag-\(conversationId)",
            creatorId: currentInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: "Test",
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
            imageLastRenewed: nil,
            isUnused: false
        ).insert(db)

        try ConversationLocalState(
            conversationId: conversationId,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: Date(),
            isMuted: false,
            pinnedOrder: nil
        ).insert(db)

        try DBConversationMember(
            conversationId: conversationId,
            inboxId: currentInboxId,
            role: .superAdmin,
            consent: .allowed,
            createdAt: Date(),
            invitedByInboxId: nil
        ).insert(db)

        try DBMemberProfile(
            conversationId: conversationId,
            inboxId: currentInboxId,
            name: "Current",
            avatar: nil
        ).insert(db)
    }

    private func insertMessage(
        db: Database,
        id: String,
        conversationId: String,
        dateNs: Int64,
        sortId: Int64
    ) throws {
        try DBMessage(
            id: id,
            clientMessageId: id,
            conversationId: conversationId,
            senderId: "current-user",
            dateNs: dateNs,
            date: Date(timeIntervalSince1970: Double(dateNs) / 1_000_000_000),
            sortId: sortId,
            status: .published,
            messageType: .original,
            contentType: .text,
            text: "message \(id)",
            emoji: nil,
            invite: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            update: nil
        ).insert(db)
    }

    private func verifySortOrder(
        db: MockDatabaseManager,
        conversationId: String,
        expected: [String]
    ) throws {
        let messages = try db.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .order(DBMessage.Columns.sortId.asc)
                .fetchAll(db)
        }
        for (index, msg) in messages.enumerated() {
            #expect(msg.id == expected[index], "Message at position \(index) should be \(expected[index]) but was \(msg.id)")
        }
    }
}
