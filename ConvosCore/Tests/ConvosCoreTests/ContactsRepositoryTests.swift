@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ContactsRepository Tests", .serialized)
struct ContactsRepositoryTests {
    @Test("fetchAll returns contacts sorted alphabetically by displayName")
    func testAlphabeticalSort() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "inbox-charlie",
                addedAt: Date(timeIntervalSince1970: 1),
                addedViaConversationId: nil,
                displayName: "Charlie"
            ).save(db)
            try DBContact(
                inboxId: "inbox-alice",
                addedAt: Date(timeIntervalSince1970: 2),
                addedViaConversationId: nil,
                displayName: "alice"
            ).save(db)
            try DBContact(
                inboxId: "inbox-bob",
                addedAt: Date(timeIntervalSince1970: 3),
                addedViaConversationId: nil,
                displayName: "Bob"
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        let contacts = try repo.fetchAll()

        #expect(contacts.map(\.inboxId) == ["inbox-alice", "inbox-bob", "inbox-charlie"])
    }

    @Test("isContact returns true only for inboxIds with a contact row")
    func testIsContactLookup() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "known",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Known"
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        #expect(try repo.isContact(inboxId: "known") == true)
        #expect(try repo.isContact(inboxId: "stranger") == false)
    }

    @Test("Contacts with nil displayName fall back to truncated inboxId in the sort key")
    func testNilDisplayNameFallback() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "zzzzzzzz",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: nil
            ).save(db)
            try DBContact(
                inboxId: "aaa",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Mid"
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        let names = try repo.fetchAll().map(\.resolvedDisplayName)
        // "Mid" sorts before "zzzzzzzz" by case-insensitive compare
        #expect(names == ["Mid", "zzzzzzzz"])
    }
}
