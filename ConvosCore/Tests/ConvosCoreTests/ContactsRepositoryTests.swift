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

    @Test("isBlocked is false for unknown inboxIds and unblocked contacts, true for blocked contacts")
    func testIsBlockedLookup() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "unblocked",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Unblocked"
            ).save(db)
            try DBContact(
                inboxId: "blocked",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Blocked",
                blockedAt: Date()
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        #expect(try repo.isBlocked(inboxId: "blocked") == true)
        #expect(try repo.isBlocked(inboxId: "unblocked") == false)
        #expect(try repo.isBlocked(inboxId: "stranger") == false)
    }

    @Test("fetchAll includes blocked contacts so the browse list can offer an unblock affordance")
    func testFetchAllIncludesBlockedContacts() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try dbManager.dbWriter.write { db in
            try DBContact(
                inboxId: "alice",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Alice"
            ).save(db)
            try DBContact(
                inboxId: "bob",
                addedAt: Date(),
                addedViaConversationId: nil,
                displayName: "Bob",
                blockedAt: Date()
            ).save(db)
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        let contacts = try repo.fetchAll()

        #expect(contacts.map(\.inboxId) == ["alice", "bob"])
        let bob = contacts.first { $0.inboxId == "bob" }
        #expect(bob?.isBlocked == true)
        let alice = contacts.first { $0.inboxId == "alice" }
        #expect(alice?.isBlocked == false)
    }

    @Test("Contacts with nil displayName fall back to \"Somebody\" in the sort key")
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
        // The nil-name contact resolves to "Somebody", not its inboxId, so
        // it sorts by "Somebody" - after "Mid" by case-insensitive compare.
        #expect(names == ["Mid", "Somebody"])
    }

    @Test("sourceConversations returns the convo name + kind for each id, drops missing ids")
    func testSourceConversationsBatched() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let now = Date()

        try dbManager.dbWriter.write { db in
            try DBMember(inboxId: "current").save(db, onConflict: .ignore)
            try DBConversation(
                id: "convo-dm",
                clientConversationId: "client-convo-dm",
                inviteTag: "tag-convo-dm",
                creatorId: "current",
                kind: .dm,
                consent: .allowed,
                createdAt: now,
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
            try DBConversation(
                id: "convo-group",
                clientConversationId: "client-convo-group",
                inviteTag: "tag-convo-group",
                creatorId: "current",
                kind: .group,
                consent: .allowed,
                createdAt: now,
                name: "Trip Planning",
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
        }

        let repo = ContactsRepository(databaseReader: dbManager.dbReader)
        let sources = try repo.sourceConversations(forIds: [
            "convo-dm",
            "convo-group",
            "missing-convo"
        ])

        #expect(sources.count == 2)
        #expect(sources["convo-dm"]?.kind == .dm)
        #expect(sources["convo-dm"]?.name == nil)
        #expect(sources["convo-group"]?.kind == .group)
        #expect(sources["convo-group"]?.name == "Trip Planning")
        #expect(sources["missing-convo"] == nil)
    }

    @Test("sourceConversations is a no-op for an empty input set")
    func testSourceConversationsEmpty() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let repo = ContactsRepository(databaseReader: dbManager.dbReader)

        let sources = try repo.sourceConversations(forIds: [])

        #expect(sources.isEmpty)
    }
}
