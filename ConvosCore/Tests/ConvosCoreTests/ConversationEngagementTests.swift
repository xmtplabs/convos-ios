@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for the engagement keep rule: `ConversationEngagement.isEngaged`
/// (the predicate the guarded discard reads), the `hasHadOtherMembers`
/// high-water mark set points, the migration backfill, and
/// `SessionManager.discardClaimedConversationIfUnengaged`'s keep path.
@Suite("Conversation engagement keep rule", .serialized)
struct ConversationEngagementTests {
    private static let currentInboxId: String = "inbox-current"
    private static let otherInboxId: String = "inbox-other"

    // MARK: - Seeding

    private static func seedInbox(db: Database) throws {
        try DBMember(inboxId: currentInboxId).save(db, onConflict: .ignore)
        try DBInbox(
            inboxId: currentInboxId,
            clientId: "client-current",
            createdAt: Date()
        ).save(db, onConflict: .ignore)
    }

    /// Seeds a conversation shaped like a fresh pool row: all-nil metadata,
    /// the local inbox as sole member, no messages. Parameters deviate from
    /// that baseline per test.
    private static func seedPoolConversation(
        db: Database,
        id: String,
        name: String? = nil,
        description: String? = nil,
        emoji: String? = nil,
        imageURLString: String? = nil,
        isUnused: Bool = true,
        hasHadOtherMembers: Bool = false,
        includeOtherMember: Bool = false
    ) throws {
        try seedInbox(db: db)

        try DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "tag-\(id)",
            creatorId: currentInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: name,
            description: description,
            imageURLString: imageURLString,
            publicImageURLString: nil,
            includeInfoInPublicPreview: true,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: emoji,
            imageLastRenewed: nil,
            isUnused: isUnused,
            hasHadVerifiedAgent: false
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
            hasHadOtherMembers: hasHadOtherMembers
        ).insert(db)

        var memberInboxIds: [String] = [currentInboxId]
        if includeOtherMember {
            memberInboxIds.append(otherInboxId)
        }
        for inboxId in memberInboxIds {
            try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
            try DBConversationMember(
                conversationId: id,
                inboxId: inboxId,
                role: inboxId == currentInboxId ? .superAdmin : .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
        }
    }

    private static func seedMessage(
        db: Database,
        id: String,
        conversationId: String,
        contentType: MessageContentType,
        messageType: DBMessageType = .original
    ) throws {
        try DBMessage(
            id: id,
            clientMessageId: id,
            conversationId: conversationId,
            senderId: currentInboxId,
            dateNs: 1,
            date: Date(),
            sortId: nil,
            status: .published,
            messageType: messageType,
            contentType: contentType,
            text: contentType == .text ? "hello" : nil,
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            update: nil
        ).insert(db)
    }

    private static func isEngaged(_ db: Database, id: String) throws -> Bool {
        try ConversationEngagement.isEngaged(db, conversationId: id, currentInboxId: currentInboxId)
    }

    // MARK: - isEngaged truth table

    @Test("Fresh pool row is not engaged")
    func freshPoolRowNotEngaged() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let engaged = try dbManager.dbWriter.write { db in
            try Self.seedPoolConversation(db: db, id: "convo")
            return try Self.isEngaged(db, id: "convo")
        }
        #expect(engaged == false)
    }

    @Test("Missing conversation is not engaged")
    func missingConversationNotEngaged() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let engaged = try dbManager.dbWriter.write { db in
            try Self.isEngaged(db, id: "missing")
        }
        #expect(engaged == false)
    }

    @Test("Each customized metadata field marks the conversation engaged")
    func metadataCustomizationEngages() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let results: [Bool] = try dbManager.dbWriter.write { db in
            try Self.seedPoolConversation(db: db, id: "named", name: "Keep Me")
            try Self.seedPoolConversation(db: db, id: "described", description: "About us")
            try Self.seedPoolConversation(db: db, id: "emojied", emoji: "🎉")
            try Self.seedPoolConversation(db: db, id: "pictured", imageURLString: "https://example.com/pic.jpg")
            return try ["named", "described", "emojied", "pictured"].map { (id: String) -> Bool in
                try Self.isEngaged(db, id: id)
            }
        }
        #expect(results == [true, true, true, true])
    }

    @Test("Empty-string metadata does not count as customization")
    func emptyStringMetadataNotEngaged() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let engaged = try dbManager.dbWriter.write { db in
            try Self.seedPoolConversation(db: db, id: "convo", name: "", description: "", emoji: "")
            return try Self.isEngaged(db, id: "convo")
        }
        #expect(engaged == false)
    }

    @Test("A chat message marks the conversation engaged")
    func chatMessageEngages() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let engaged = try dbManager.dbWriter.write { db in
            try Self.seedPoolConversation(db: db, id: "convo")
            try Self.seedMessage(db: db, id: "m1", conversationId: "convo", contentType: .text)
            return try Self.isEngaged(db, id: "convo")
        }
        #expect(engaged == true)
    }

    @Test("Membership-update rows alone do not engage")
    func updateOnlyRowsNotEngaged() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let engaged = try dbManager.dbWriter.write { db in
            try Self.seedPoolConversation(db: db, id: "convo")
            try Self.seedMessage(db: db, id: "u1", conversationId: "convo", contentType: .update)
            try Self.seedMessage(db: db, id: "u2", conversationId: "convo", contentType: .connectionEvent)
            return try Self.isEngaged(db, id: "convo")
        }
        #expect(engaged == false)
    }

    @Test("A current other member marks the conversation engaged")
    func otherMemberEngages() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let engaged = try dbManager.dbWriter.write { db in
            try Self.seedPoolConversation(db: db, id: "convo", includeOtherMember: true)
            return try Self.isEngaged(db, id: "convo")
        }
        #expect(engaged == true)
    }

    @Test("hasHadOtherMembers keeps a joined-then-left conversation engaged")
    func hasHadOtherMembersEngages() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let engaged = try dbManager.dbWriter.write { db in
            try Self.seedPoolConversation(db: db, id: "convo", hasHadOtherMembers: true)
            return try Self.isEngaged(db, id: "convo")
        }
        #expect(engaged == true)
    }

    // MARK: - markHasHadOtherMembersIfNeeded

    @Test("Synced member list with another inbox latches the flag")
    func syncedOtherMemberLatchesFlag() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let state = try dbManager.dbWriter.write { db -> ConversationLocalState? in
            try Self.seedPoolConversation(db: db, id: "convo")
            try ConversationWriter.markHasHadOtherMembersIfNeeded(
                conversationId: "convo",
                currentMemberInboxIds: [Self.currentInboxId, Self.otherInboxId],
                in: db
            )
            return try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == "convo")
                .fetchOne(db)
        }
        #expect(state?.hasHadOtherMembers == true)
    }

    @Test("Solo member list leaves the flag unset")
    func soloMemberListLeavesFlagUnset() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let state = try dbManager.dbWriter.write { db -> ConversationLocalState? in
            try Self.seedPoolConversation(db: db, id: "convo")
            try ConversationWriter.markHasHadOtherMembersIfNeeded(
                conversationId: "convo",
                currentMemberInboxIds: [Self.currentInboxId],
                in: db
            )
            return try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == "convo")
                .fetchOne(db)
        }
        #expect(state?.hasHadOtherMembers == false)
    }

    @Test("Flag survives the member leaving (solo sync after a two-member sync)")
    func flagSurvivesMemberDeparture() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let result = try dbManager.dbWriter.write { db -> (flag: Bool?, engaged: Bool) in
            try Self.seedPoolConversation(db: db, id: "convo", includeOtherMember: true)
            try ConversationWriter.markHasHadOtherMembersIfNeeded(
                conversationId: "convo",
                currentMemberInboxIds: [Self.currentInboxId, Self.otherInboxId],
                in: db
            )
            // Departure sync: the member row is deleted and the next synced
            // member list is solo again.
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == "convo")
                .filter(DBConversationMember.Columns.inboxId == Self.otherInboxId)
                .deleteAll(db)
            try ConversationWriter.markHasHadOtherMembersIfNeeded(
                conversationId: "convo",
                currentMemberInboxIds: [Self.currentInboxId],
                in: db
            )
            let state = try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == "convo")
                .fetchOne(db)
            return (state?.hasHadOtherMembers, try Self.isEngaged(db, id: "convo"))
        }
        #expect(result.flag == true)
        #expect(result.engaged == true)
    }

    // MARK: - Migration backfill

    @Test("Backfill flags conversations that currently hold a non-local member row")
    func migrationBackfill() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            // Minimal prior schema: only the tables the migration touches.
            try db.create(table: "inbox") { t in
                t.column("inboxId", .text).notNull().primaryKey()
            }
            try db.create(table: "conversationLocalState") { t in
                t.column("conversationId", .text).notNull().primaryKey()
            }
            try db.create(table: "conversation_members") { t in
                t.column("conversationId", .text).notNull()
                t.column("inboxId", .text).notNull()
            }
            try db.execute(sql: "INSERT INTO inbox (inboxId) VALUES ('inbox-current')")
            // Solo minted conversation: only the local inbox as a member.
            try db.execute(sql: "INSERT INTO conversationLocalState (conversationId) VALUES ('solo')")
            try db.execute(sql: "INSERT INTO conversation_members VALUES ('solo', 'inbox-current')")
            // Conversation with a second member.
            try db.execute(sql: "INSERT INTO conversationLocalState (conversationId) VALUES ('shared')")
            try db.execute(sql: "INSERT INTO conversation_members VALUES ('shared', 'inbox-current')")
            try db.execute(sql: "INSERT INTO conversation_members VALUES ('shared', 'inbox-other')")

            try SharedDatabaseMigrator.addConversationLocalStateHasHadOtherMembers(db)
        }

        try dbQueue.read { db in
            let solo = try Bool.fetchOne(
                db,
                sql: "SELECT hasHadOtherMembers FROM conversationLocalState WHERE conversationId = 'solo'"
            )
            let shared = try Bool.fetchOne(
                db,
                sql: "SELECT hasHadOtherMembers FROM conversationLocalState WHERE conversationId = 'shared'"
            )
            #expect(solo == false)
            #expect(shared == true)
        }
    }

    // MARK: - Guarded discard

    @Test("Guarded discard keeps an engaged conversation, commits it visible, and never denies consent")
    func guardedDiscardKeepsEngagedConversation() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let session = SessionManager(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            environment: .tests,
            identityStore: MockKeychainIdentityStore(),
            platformProviders: .mock
        )
        try await dbManager.dbWriter.write { db in
            try Self.seedPoolConversation(db: db, id: "renamed", name: "Keep Me", isUnused: true)
        }

        await session.discardClaimedConversationIfUnengaged(id: "renamed")

        let conversation = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: "renamed")
        }
        let localStateCount = try await dbManager.dbReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == "renamed")
                .fetchCount(db)
        }
        #expect(conversation != nil)
        #expect(conversation?.isUnused == false)
        #expect(conversation?.consent == .allowed)
        #expect(localStateCount == 1)
    }
}
