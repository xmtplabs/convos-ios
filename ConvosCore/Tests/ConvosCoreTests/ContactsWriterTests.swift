@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ContactsWriter Tests", .serialized)
struct ContactsWriterTests {
    @Test("upsertContact preserves addedAt and addedViaConversationId on subsequent calls")
    func testIdempotentUpsertPreservesIdentityColumns() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)

        let inboxId = "inbox-1"
        let originalConversation = "conv-original"
        let later = "conv-later"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: originalConversation,
            profile: ContactProfileSnapshot(displayName: "First", profileUpdatedAt: Date(timeIntervalSince1970: 100))
        )

        let firstAddedAt = try dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)?.addedAt
        }

        // Sleep briefly so the second call's "now" is meaningfully later if
        // it ever leaked into addedAt.
        try await Task.sleep(nanoseconds: 5_000_000)

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: later,
            profile: ContactProfileSnapshot(displayName: "Second", profileUpdatedAt: Date(timeIntervalSince1970: 200))
        )

        let after = try dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }

        #expect(after?.addedAt == firstAddedAt)
        #expect(after?.addedViaConversationId == originalConversation)
        #expect(after?.displayName == "Second")
    }

    @Test("updateProfileIfNewer drops older events and applies newer ones")
    func testProfileMostRecentWins() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)

        let inboxId = "inbox-1"
        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(displayName: "Latest", profileUpdatedAt: Date(timeIntervalSince1970: 200))
        )

        // Older event — must be dropped.
        try await writer.updateProfileIfNewer(
            inboxId: inboxId,
            profile: ContactProfileSnapshot(displayName: "Older", profileUpdatedAt: Date(timeIntervalSince1970: 100))
        )

        var contact = try dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Latest")

        // Newer event — must be applied.
        try await writer.updateProfileIfNewer(
            inboxId: inboxId,
            profile: ContactProfileSnapshot(displayName: "Newest", profileUpdatedAt: Date(timeIntervalSince1970: 300))
        )

        contact = try dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Newest")
    }

    @Test("updateProfileIfNewer no-ops when contact does not exist")
    func testUpdateProfileForUnknownContactNoOps() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)

        try await writer.updateProfileIfNewer(
            inboxId: "ghost",
            profile: ContactProfileSnapshot(displayName: "Ghost")
        )

        let count = try dbManager.dbReader.read { db in
            try DBContact.fetchCount(db)
        }
        #expect(count == 0)
    }

    @Test("applyMemberProfileInTransaction mirrors a name update onto the contact row")
    func testApplyMemberProfileInTransactionUpdatesName() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        // Seed a contact with no name (the inboxId-fallback case in the UI).
        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(profileUpdatedAt: Date(timeIntervalSince1970: 100))
        )

        // A profile event arrives later naming the inbox "Mickey".
        try await dbManager.dbWriter.write { db in
            try ContactsWriter.applyMemberProfileInTransaction(
                db: db,
                inboxId: inboxId,
                name: "Mickey",
                avatarURL: "https://example.com/mickey.png",
                receivedAt: Date(timeIntervalSince1970: 200)
            )
        }

        let contact = try dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Mickey")
        #expect(contact?.avatarURL == "https://example.com/mickey.png")
    }

    @Test("applyMemberProfileInTransaction no-ops when the inboxId has no contact row")
    func testApplyMemberProfileInTransactionNoOpsForUnknownInbox() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try await dbManager.dbWriter.write { db in
            try ContactsWriter.applyMemberProfileInTransaction(
                db: db,
                inboxId: "stranger",
                name: "Mickey",
                avatarURL: nil,
                receivedAt: Date()
            )
        }

        let count = try dbManager.dbReader.read { db in
            try DBContact.fetchCount(db)
        }
        #expect(count == 0)
    }

    @Test("applyMemberProfileInTransaction respects most-recent-wins")
    func testApplyMemberProfileInTransactionRespectsRecency() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(displayName: "Newer", profileUpdatedAt: Date(timeIntervalSince1970: 200))
        )

        // An older profile event must NOT overwrite the stored name.
        try await dbManager.dbWriter.write { db in
            try ContactsWriter.applyMemberProfileInTransaction(
                db: db,
                inboxId: inboxId,
                name: "Older",
                avatarURL: nil,
                receivedAt: Date(timeIntervalSince1970: 100)
            )
        }

        let contact = try dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Newer")
    }

    @Test("upsertContact merges partial profile snapshots")
    func testPartialProfileMerge() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(
                displayName: "Original",
                avatarURL: "https://example.com/a.jpg",
                profileUpdatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        // Newer partial event with only a name — must not clobber avatarURL.
        try await writer.updateProfileIfNewer(
            inboxId: inboxId,
            profile: ContactProfileSnapshot(displayName: "Renamed", profileUpdatedAt: Date(timeIntervalSince1970: 200))
        )

        let contact = try dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Renamed")
        #expect(contact?.avatarURL == "https://example.com/a.jpg")
    }
}
