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
}
