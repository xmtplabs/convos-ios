@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Tests for InboxWriter
///
/// Tests cover:
/// - Saving new inbox
/// - Detecting clientId mismatch (invariant violation)
/// - Idempotent saves with matching clientId
@Suite("InboxWriter Tests")
struct InboxWriterTests {
    @Test("Save creates new inbox in database")
    func testSaveNewInbox() async throws {
        let fixtures = TestFixtures()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "test-inbox-id"
        let clientId = ClientId.generate().value

        let savedInbox = try await inboxWriter.save(inboxId: inboxId, clientId: clientId)

        #expect(savedInbox.inboxId == inboxId)
        #expect(savedInbox.clientId == clientId)

        // Verify it's in the database
        let dbInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)
        }

        #expect(dbInbox != nil)
        #expect(dbInbox?.clientId == clientId)

        try? await fixtures.cleanup()
    }

    @Test("Save is idempotent when clientId matches")
    func testSaveIdempotentWithMatchingClientId() async throws {
        let fixtures = TestFixtures()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "test-inbox-id"
        let clientId = ClientId.generate().value

        // Save once
        let firstSave = try await inboxWriter.save(inboxId: inboxId, clientId: clientId)

        // Save again with same clientId
        let secondSave = try await inboxWriter.save(inboxId: inboxId, clientId: clientId)

        #expect(firstSave.inboxId == secondSave.inboxId)
        #expect(firstSave.clientId == secondSave.clientId)

        // Verify only one record in database
        let dbInboxes = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchAll(db)
        }

        #expect(dbInboxes.count == 1)

        try? await fixtures.cleanup()
    }

    @Test("Save updates installationId for existing inbox")
    func testSaveUpdatesInstallationId() async throws {
        let fixtures = TestFixtures()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "test-inbox-id"
        let clientId = ClientId.generate().value

        _ = try await inboxWriter.save(inboxId: inboxId, clientId: clientId)

        let installationId = "installation-123"
        let updatedInbox = try await inboxWriter.save(
            inboxId: inboxId,
            clientId: clientId,
            installationId: installationId
        )

        #expect(updatedInbox.installationId == installationId)

        let dbInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)
        }
        #expect(dbInbox?.installationId == installationId)

        try? await fixtures.cleanup()
    }

    @Test("Save throws error when clientId doesn't match (invariant violation)")
    func testSaveThrowsOnClientIdMismatch() async throws {
        let fixtures = TestFixtures()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "test-inbox-id"
        let originalClientId = ClientId.generate().value
        let differentClientId = ClientId.generate().value

        // Save with original clientId
        _ = try await inboxWriter.save(inboxId: inboxId, clientId: originalClientId)

        // Attempt to save with different clientId should throw
        await #expect(throws: InboxWriterError.self) {
            try await inboxWriter.save(inboxId: inboxId, clientId: differentClientId)
        }

        // Verify the original clientId is still in database (unchanged)
        let dbInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)
        }

        #expect(dbInbox?.clientId == originalClientId)

        try? await fixtures.cleanup()
    }

    @Test("Delete removes inbox from database")
    func testDeleteInbox() async throws {
        let fixtures = TestFixtures()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "test-inbox-id"
        let clientId = ClientId.generate().value

        // Save inbox
        _ = try await inboxWriter.save(inboxId: inboxId, clientId: clientId)

        // Verify it exists
        var dbInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)
        }
        #expect(dbInbox != nil)

        // Delete it
        try await inboxWriter.delete(inboxId: inboxId)

        // Verify it's gone
        dbInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)
        }
        #expect(dbInbox == nil)

        try? await fixtures.cleanup()
    }

    @Test("Delete by clientId removes inbox from database")
    func testDeleteByClientId() async throws {
        let fixtures = TestFixtures()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "test-inbox-id"
        let clientId = ClientId.generate().value

        // Save inbox
        _ = try await inboxWriter.save(inboxId: inboxId, clientId: clientId)

        // Delete by clientId
        try await inboxWriter.delete(clientId: clientId)

        // Verify it's gone
        let dbInbox = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)
        }
        #expect(dbInbox == nil)

        try? await fixtures.cleanup()
    }

    @Test("markStale flips an inbox's isStale flag")
    func testMarkStaleFlipsFlag() async throws {
        let fixtures = TestFixtures()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        let inboxId = "stale-inbox"
        _ = try await inboxWriter.save(inboxId: inboxId, clientId: ClientId.generate().value)

        let initial = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)?.isStale
        }
        #expect(initial == false)

        try await inboxWriter.markStale(inboxId: inboxId)
        let afterMark = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)?.isStale
        }
        #expect(afterMark == true)

        try await inboxWriter.markStale(inboxId: inboxId, false)
        let afterClear = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: inboxId)?.isStale
        }
        #expect(afterClear == false)

        try? await fixtures.cleanup()
    }

    @Test("markStale only affects the targeted inbox")
    func testMarkStaleIsScopedToOneInbox() async throws {
        let fixtures = TestFixtures()
        let inboxWriter = InboxWriter(dbWriter: fixtures.databaseManager.dbWriter)

        _ = try await inboxWriter.save(inboxId: "inbox-a", clientId: ClientId.generate().value)
        _ = try await inboxWriter.save(inboxId: "inbox-b", clientId: ClientId.generate().value)

        try await inboxWriter.markStale(inboxId: "inbox-a")

        let stale = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: "inbox-a")?.isStale
        }
        let other = try await fixtures.databaseManager.dbReader.read { db in
            try DBInbox.fetchOne(db, id: "inbox-b")?.isStale
        }
        #expect(stale == true)
        #expect(other == false)

        try? await fixtures.cleanup()
    }

    @Test("deleteAll removes data from all tables")
    func testDeleteAllRemovesAllData() async throws {
        let fixtures = TestFixtures()
        let db = fixtures.databaseManager.dbWriter

        let inboxWriter = InboxWriter(dbWriter: db)
        _ = try await inboxWriter.save(inboxId: "inbox-1", clientId: "client-1")

        try await db.write { db in
            let conversation = DBConversation(
                id: "conv-1",
                inboxId: "inbox-1",
                clientId: "client-1",
                clientConversationId: "conv-1",
                inviteTag: "",
                creatorId: "inbox-1",
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
                imageLastRenewed: nil,
                isUnused: false
            )
            try conversation.save(db)

            let member = DBMember(inboxId: "inbox-1")
            try member.save(db)

            let memberProfile = DBMemberProfile(
                conversationId: "conv-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: nil
            )
            try memberProfile.save(db)

            let localState = ConversationLocalState(
                conversationId: "conv-1",
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date(),
                isMuted: false,
                pinnedOrder: nil,
                isActive: true
            )
            try localState.save(db)

            let conversationMember = DBConversationMember(
                conversationId: "conv-1",
                inboxId: "inbox-1",
                role: .superAdmin,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            )
            try conversationMember.save(db)

            // invite references conversation_members via composite FK
            // (creatorInboxId + conversationId). This exercises the FK ordering
            // in deleteAll: invite must be deleted before conversation_members
            // (or cascade must fire) to avoid constraint violations.
            let invite = DBInvite(
                creatorInboxId: "inbox-1",
                conversationId: "conv-1",
                urlSlug: "test-slug",
                expiresAt: nil,
                expiresAfterUse: false
            )
            try invite.save(db)
        }

        try await inboxWriter.deleteAll()

        let counts = try await fixtures.databaseManager.dbReader.read { db in
            (
                inbox: try DBInbox.fetchCount(db),
                conversation: try DBConversation.fetchCount(db),
                member: try DBMember.fetchCount(db),
                memberProfile: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memberProfile") ?? 0,
                localState: try ConversationLocalState.fetchCount(db),
                conversationMembers: try DBConversationMember.fetchCount(db),
                invite: try DBInvite.fetchCount(db)
            )
        }

        #expect(counts.inbox == 0)
        #expect(counts.conversation == 0)
        #expect(counts.member == 0)
        #expect(counts.memberProfile == 0)
        #expect(counts.localState == 0)
        #expect(counts.conversationMembers == 0)
        #expect(counts.invite == 0)

        try? await fixtures.cleanup()
    }
}
