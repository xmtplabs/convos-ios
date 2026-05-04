@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ContactsBackfillService Tests", .serialized)
struct ContactsBackfillServiceTests {
    private static func seedConversation(
        db: Database,
        conversationId: String,
        creatorInboxId: String,
        memberInboxIds: [String]
    ) throws {
        try DBMember(inboxId: creatorInboxId).save(db, onConflict: .ignore)
        for inboxId in memberInboxIds {
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
        }
        try DBConversation(
            id: conversationId,
            clientConversationId: conversationId,
            inviteTag: "tag-\(conversationId)",
            creatorId: creatorInboxId,
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
            hasHadVerifiedAssistant: false
        ).insert(db)
        for inboxId in memberInboxIds {
            try DBConversationMember(
                conversationId: conversationId,
                inboxId: inboxId,
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).save(db)
        }
    }

    private static func seedOutboundMessage(
        db: Database,
        conversationId: String,
        senderId: String,
        offset: Int = 0
    ) throws {
        let messageId = "\(conversationId)-msg-\(offset)"
        try DBMessage(
            id: messageId,
            clientMessageId: messageId,
            conversationId: conversationId,
            senderId: senderId,
            dateNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000),
            date: Date(),
            sortId: Int64(offset + 1),
            status: .published,
            messageType: .original,
            contentType: .text,
            text: "hello",
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            update: nil
        ).insert(db)
    }

    @Test("Backfill syncs only conversations with at least one outbound message and no sync marker")
    func testBackfillScopedToActedInConversations() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let selfInboxId = "self-inbox"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: selfInboxId, clientId: "client").save(db)

            try Self.seedConversation(
                db: db,
                conversationId: "acted",
                creatorInboxId: selfInboxId,
                memberInboxIds: [selfInboxId, "alice"]
            )
            try Self.seedOutboundMessage(db: db, conversationId: "acted", senderId: selfInboxId)

            try Self.seedConversation(
                db: db,
                conversationId: "lurked",
                creatorInboxId: "stranger",
                memberInboxIds: [selfInboxId, "stranger"]
            )
            // Note: no outbound message in "lurked" — we are a passive participant.
        }

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        let backfill = ContactsBackfillService(
            databaseReader: dbManager.dbReader,
            coordinator: coordinator
        )
        try await backfill.backfillIfNeeded()

        let inboxIds: Set<String> = try await dbManager.dbReader.read { db in
            Set(try DBContact.fetchAll(db).map(\.inboxId))
        }
        #expect(inboxIds == Set(["alice"]))

        let markers: [String] = try await dbManager.dbReader.read { db in
            try DBConversationContactsSync.fetchAll(db).map(\.conversationId)
        }
        #expect(markers == ["acted"])
    }

    @Test("Backfill no-ops when there is no inbox")
    func testBackfillRequiresInbox() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        let coordinator = ContactSyncCoordinator(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader
        )
        let backfill = ContactsBackfillService(
            databaseReader: dbManager.dbReader,
            coordinator: coordinator
        )
        try await backfill.backfillIfNeeded()

        let count = try await dbManager.dbReader.read { db in
            try DBContact.fetchCount(db)
        }
        #expect(count == 0)
    }
}
