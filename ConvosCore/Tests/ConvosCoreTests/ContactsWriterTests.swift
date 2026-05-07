@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ContactsWriter Tests", .serialized)
struct ContactsWriterTests {
    /// Inserts a minimal `conversation` row so a contact can FK against it.
    /// `contact.addedViaConversationId` references `conversation(id)`; tests
    /// that exercise non-nil `addedViaConversationId` need the parent row to
    /// exist first.
    private static func seedMinimalConversation(_ db: Database, id: String) throws {
        let creatorInboxId = "creator-\(id)"
        try DBMember(inboxId: creatorInboxId).save(db, onConflict: .ignore)
        try DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "tag-\(id)",
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
    }

    @Test("upsertContact preserves addedAt and addedViaConversationId on subsequent calls")
    func testIdempotentUpsertPreservesIdentityColumns() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)

        let inboxId = "inbox-1"
        let originalConversation = "conv-original"
        let later = "conv-later"

        try await dbManager.dbWriter.write { db in
            try Self.seedMinimalConversation(db, id: originalConversation)
            try Self.seedMinimalConversation(db, id: later)
        }

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: originalConversation,
            profile: ContactProfileSnapshot(displayName: "First", profileUpdatedAt: Date(timeIntervalSince1970: 100))
        )

        let firstAddedAt = try await dbManager.dbReader.read { db in
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

        let after = try await dbManager.dbReader.read { db in
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

        var contact = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Latest")

        // Newer event — must be applied.
        try await writer.updateProfileIfNewer(
            inboxId: inboxId,
            profile: ContactProfileSnapshot(displayName: "Newest", profileUpdatedAt: Date(timeIntervalSince1970: 300))
        )

        contact = try await dbManager.dbReader.read { db in
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

        let count = try await dbManager.dbReader.read { db in
            try DBContact.fetchCount(db)
        }
        #expect(count == 0)
    }

    @Test("mirrorMemberProfileToContactInTransaction mirrors a name update onto the contact row")
    func testMirrorMemberProfileToContactUpdatesName() async throws {
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
            try ContactsWriter.mirrorMemberProfileToContactInTransaction(
                db: db,
                inboxId: inboxId,
                name: "Mickey",
                avatarURL: "https://example.com/mickey.png",
                receivedAt: Date(timeIntervalSince1970: 200)
            )
        }

        let contact = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Mickey")
        #expect(contact?.avatarURL == "https://example.com/mickey.png")
    }

    @Test("mirrorMemberProfileToContactInTransaction no-ops when the inboxId has no contact row")
    func testMirrorMemberProfileToContactNoOpsForUnknownInbox() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try await dbManager.dbWriter.write { db in
            try ContactsWriter.mirrorMemberProfileToContactInTransaction(
                db: db,
                inboxId: "stranger",
                name: "Mickey",
                avatarURL: nil,
                receivedAt: Date()
            )
        }

        let count = try await dbManager.dbReader.read { db in
            try DBContact.fetchCount(db)
        }
        #expect(count == 0)
    }

    @Test("mirrorMemberProfileToContactInTransaction respects most-recent-wins")
    func testMirrorMemberProfileToContactRespectsRecency() async throws {
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
            try ContactsWriter.mirrorMemberProfileToContactInTransaction(
                db: db,
                inboxId: inboxId,
                name: "Older",
                avatarURL: nil,
                receivedAt: Date(timeIntervalSince1970: 100)
            )
        }

        let contact = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Newer")
    }

    @Test("block sets blockedAt on an existing contact and is idempotent")
    func testBlockIsIdempotent() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(displayName: "Test")
        )

        try await writer.block(inboxId: inboxId)
        let firstBlockedAt = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)?.blockedAt
        }
        #expect(firstBlockedAt != nil)

        // Sleep briefly so a second block call would produce a meaningfully
        // different timestamp if it overwrote the original.
        try await Task.sleep(nanoseconds: 5_000_000)

        try await writer.block(inboxId: inboxId)
        let secondBlockedAt = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)?.blockedAt
        }
        #expect(secondBlockedAt == firstBlockedAt)
    }

    @Test("unblock clears blockedAt and is idempotent")
    func testUnblockIsIdempotent() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(displayName: "Test")
        )
        try await writer.block(inboxId: inboxId)

        try await writer.unblock(inboxId: inboxId)
        var blockedAt = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)?.blockedAt
        }
        #expect(blockedAt == nil)

        // Repeat unblock on an already-unblocked contact must not error.
        try await writer.unblock(inboxId: inboxId)
        blockedAt = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)?.blockedAt
        }
        #expect(blockedAt == nil)
    }

    @Test("block no-ops when the inboxId has no contact row")
    func testBlockUnknownContactNoOps() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)

        try await writer.block(inboxId: "ghost")

        let count = try await dbManager.dbReader.read { db in
            try DBContact.fetchCount(db)
        }
        #expect(count == 0)
    }

    @Test("block followed by unblock returns the contact to the unblocked state")
    func testBlockUnblockRoundTrip() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(displayName: "Test")
        )

        try await writer.block(inboxId: inboxId)
        try await writer.unblock(inboxId: inboxId)
        try await writer.block(inboxId: inboxId)

        let contact = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.blockedAt != nil)
    }

    @Test("Profile updates do not clobber the blocked flag")
    func testProfileUpdatePreservesBlockedAt() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(displayName: "Original", profileUpdatedAt: Date(timeIntervalSince1970: 100))
        )
        try await writer.block(inboxId: inboxId)

        try await writer.updateProfileIfNewer(
            inboxId: inboxId,
            profile: ContactProfileSnapshot(displayName: "Renamed", profileUpdatedAt: Date(timeIntervalSince1970: 200))
        )

        let contact = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Renamed")
        #expect(contact?.blockedAt != nil)
    }

    @Test("agentVerification persists on a new contact via upsert")
    func testAgentVerificationPersistsOnNewContact() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-agent"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(
                displayName: "Agent",
                profileUpdatedAt: Date(timeIntervalSince1970: 100),
                agentVerification: .verified(.convos)
            )
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(stored?.agentVerification == .verified(.convos))
    }

    @Test("Newer agentVerification overrides older")
    func testAgentVerificationMostRecentWins() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(
                profileUpdatedAt: Date(timeIntervalSince1970: 100),
                agentVerification: .unverified
            )
        )

        try await writer.updateProfileIfNewer(
            inboxId: inboxId,
            profile: ContactProfileSnapshot(
                profileUpdatedAt: Date(timeIntervalSince1970: 200),
                agentVerification: .verified(.userOAuth)
            )
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(stored?.agentVerification == .verified(.userOAuth))
    }

    @Test("Profile update without agentVerification preserves the existing verification")
    func testAgentVerificationPreservedOnNilSignal() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(
                displayName: "Original",
                profileUpdatedAt: Date(timeIntervalSince1970: 100),
                agentVerification: .verified(.convos)
            )
        )

        // Newer profile event from a non-agent context (nil agentVerification).
        try await writer.updateProfileIfNewer(
            inboxId: inboxId,
            profile: ContactProfileSnapshot(
                displayName: "Renamed",
                profileUpdatedAt: Date(timeIntervalSince1970: 200),
                agentVerification: nil
            )
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(stored?.displayName == "Renamed")
        #expect(stored?.agentVerification == .verified(.convos))
    }

    @Test("applyMemberProfileInTransaction promotes a contact's verification when passed in")
    func testApplyMemberProfilePromotesAgentVerification() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(profileUpdatedAt: Date(timeIntervalSince1970: 100))
        )

        try await dbManager.dbWriter.write { db in
            try ContactsWriter.applyMemberProfileInTransaction(
                db: db,
                inboxId: inboxId,
                name: "Agent",
                avatarURL: nil,
                receivedAt: Date(timeIntervalSince1970: 200),
                agentVerification: .verified(.convos)
            )
        }

        let stored = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(stored?.agentVerification == .verified(.convos))
    }

    @Test("Untimestamped snapshot does not overwrite a more-recent stored name (Robert/Bob bug)")
    func testUntimestampedSnapshotPreservesNewerStoredData() async throws {
        // Robert/Bob scenario: contact already updated to "Bob" via a
        // timestamped ProfileUpdate from conversation A. Later, a coordinator-
        // style sync fires from conversation B (where the per-conversation
        // profile still says "Robert" and has no timestamp). The contact
        // must remain "Bob" — untimestamped snapshots are "fill defaults"
        // data and never overwrite known fields.
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "robert-inbox"

        // Initial seed: contact added with "Robert" via timestamped event.
        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(
                displayName: "Robert",
                profileUpdatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        // ProfileUpdate from conv-A: name → Bob.
        try await writer.updateProfileIfNewer(
            inboxId: inboxId,
            profile: ContactProfileSnapshot(
                displayName: "Bob",
                profileUpdatedAt: Date(timeIntervalSince1970: 200)
            )
        )

        let afterUpdate = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(afterUpdate?.displayName == "Bob")
        let bobTimestamp = afterUpdate?.profileUpdatedAt

        // Coordinator re-sync from conv-B: per-conversation profile still
        // says "Robert", snapshot has nil timestamp.
        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: "conv-b",
            profile: ContactProfileSnapshot(
                displayName: "Robert",
                profileUpdatedAt: nil
            )
        )

        let afterCoordinator = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        // Bob should win — untimestamped snapshot didn't claim freshness.
        #expect(afterCoordinator?.displayName == "Bob")
        // The stored timestamp should remain the Bob-update timestamp,
        // not be advanced to "now" by the coordinator's nil-timestamp call.
        #expect(afterCoordinator?.profileUpdatedAt == bobTimestamp)
    }

    @Test("Untimestamped snapshot fills nil/empty fields on existing contact")
    func testUntimestampedSnapshotFillsNilFieldsOnly() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        // Seed contact with only a display name.
        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(
                displayName: "Alice",
                profileUpdatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        // Coordinator-style untimestamped snapshot with both name and avatar.
        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(
                displayName: "AliceFromConvB",
                avatarURL: "https://example.com/a.jpg",
                profileUpdatedAt: nil
            )
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        // Name preserved (already set by timestamped path).
        #expect(stored?.displayName == "Alice")
        // Avatar filled in (was nil, no risk of overwriting "known" data).
        #expect(stored?.avatarURL == "https://example.com/a.jpg")
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

        let contact = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Renamed")
        #expect(contact?.avatarURL == "https://example.com/a.jpg")
    }
}
