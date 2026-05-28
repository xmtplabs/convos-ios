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
            hasHadVerifiedAgent: false
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

    @Test("mirrorMemberProfileToContactInTransaction mirrors avatar encryption fields onto the contact row")
    func testMirrorMemberProfileToContactCopiesEncryptionFields() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(profileUpdatedAt: Date(timeIntervalSince1970: 100))
        )

        let salt = Data(repeating: 0xAA, count: 32)
        let nonce = Data(repeating: 0xBB, count: 12)
        let key = Data(repeating: 0xCC, count: 32)

        try await dbManager.dbWriter.write { db in
            try ContactsWriter.mirrorMemberProfileToContactInTransaction(
                db: db,
                inboxId: inboxId,
                name: "Mickey",
                avatarURL: "https://example.com/mickey.png",
                avatarSalt: salt,
                avatarNonce: nonce,
                avatarKey: key,
                receivedAt: Date(timeIntervalSince1970: 200)
            )
        }

        let contact = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.avatarURL == "https://example.com/mickey.png")
        #expect(contact?.avatarSalt == salt)
        #expect(contact?.avatarNonce == nonce)
        #expect(contact?.avatarKey == key)
    }

    @Test("A newer mirror with nil avatar encryption fields wholesale-clears the stored fields")
    func testNewerMirrorWholesaleClearsAvatarEncryption() async throws {
        // Each timestamped snapshot is treated as one authoritative unit
        // (see `ContactsWriter.replacingProfile(of:with:)`). A newer mirror
        // that carries `nil` for the encryption material clears the stored
        // values just like it would clear `displayName` or `avatarURL`.
        // Callers feeding the mirror (e.g. `saveMemberProfileAndMirrorTo
        // ContactInTransaction`) are responsible for passing the full
        // `DBMemberProfile` state so this only happens when the sender's
        // profile genuinely lacks an encrypted avatar.
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        let salt = Data(repeating: 0xAA, count: 32)
        let nonce = Data(repeating: 0xBB, count: 12)
        let key = Data(repeating: 0xCC, count: 32)

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(
                displayName: "Initial",
                avatarURL: "https://example.com/a.png",
                avatarSalt: salt,
                avatarNonce: nonce,
                avatarKey: key,
                profileUpdatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        try await dbManager.dbWriter.write { db in
            try ContactsWriter.mirrorMemberProfileToContactInTransaction(
                db: db,
                inboxId: inboxId,
                name: "Renamed",
                avatarURL: nil,
                avatarSalt: nil,
                avatarNonce: nil,
                avatarKey: nil,
                receivedAt: Date(timeIntervalSince1970: 200)
            )
        }

        let contact = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Renamed")
        #expect(contact?.avatarURL == nil)
        #expect(contact?.avatarSalt == nil)
        #expect(contact?.avatarNonce == nil)
        #expect(contact?.avatarKey == nil)
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

    @Test("upsertContact posts `contactsWereAdded` only on a brand-new contact row")
    func testUpsertPostsContactsWereAddedOnInsertOnly() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-add-1"

        let recorder = NotificationRecorder(name: .contactsWereAdded)

        // First upsert on a fresh inboxId: real insert, post fires with the
        // singleton inboxId in the userInfo payload.
        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(
                displayName: "Original",
                profileUpdatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.notifications.count == 1)
        #expect(recorder.notifications.first?.userInfo?["inboxIds"] as? [String] == [inboxId])

        // Idempotent re-upsert with an older timestamp: no row change, no post.
        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(
                displayName: "Stale",
                profileUpdatedAt: Date(timeIntervalSince1970: 50)
            )
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.notifications.count == 1)

        // Profile-only update on an existing row: still no insert, no post.
        try await writer.updateProfileIfNewer(
            inboxId: inboxId,
            profile: ContactProfileSnapshot(
                displayName: "Renamed",
                profileUpdatedAt: Date(timeIntervalSince1970: 200)
            )
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.notifications.count == 1)

        recorder.stop()
    }

    @Test("Block and unblock post `contactBlockingDidChange` on real state changes only")
    func testBlockingPostsNotificationOnRealChanges() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(displayName: "Test")
        )

        let recorder = NotificationRecorder(name: .contactBlockingDidChange)

        // First block: real change → post.
        try await writer.block(inboxId: inboxId)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.notifications.count == 1)
        #expect(recorder.notifications.first?.userInfo?["inboxId"] as? String == inboxId)
        #expect(recorder.notifications.first?.userInfo?["blocked"] as? Bool == true)

        // Idempotent re-block: no change → no post.
        try await writer.block(inboxId: inboxId)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.notifications.count == 1)

        // Unblock: real change → post.
        try await writer.unblock(inboxId: inboxId)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.notifications.count == 2)
        #expect(recorder.notifications.last?.userInfo?["blocked"] as? Bool == false)

        // Idempotent re-unblock: no change → no post.
        try await writer.unblock(inboxId: inboxId)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.notifications.count == 2)

        recorder.stop()
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

    @Test("A newer profile snapshot wholesale-replaces stored fields, including clearing agentVerification")
    func testNewerSnapshotClearsAgentVerificationWholesale() async throws {
        // The writer treats each timestamped snapshot as one authoritative
        // unit. A newer snapshot with `agentVerification: nil` clears the
        // stored verification; the wire-format contract for `ProfileUpdate`
        // says a profile without an agent signal does not carry one.
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
        #expect(stored?.agentVerification == nil)
    }

    @Test("mirrorMemberProfileToContactInTransaction promotes a contact's verification when passed in")
    func testMirrorMemberProfilePromotesAgentVerification() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(profileUpdatedAt: Date(timeIntervalSince1970: 100))
        )

        try await dbManager.dbWriter.write { db in
            try ContactsWriter.mirrorMemberProfileToContactInTransaction(
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

    @Test("Untimestamped upsert leaves an existing contact untouched")
    func testUntimestampedUpsertNoOpsOnExistingContact() async throws {
        // An untimestamped snapshot is a "fill-defaults" payload from a
        // local hydration site (e.g. `ContactSyncCoordinator` reading per-
        // conversation member profiles). The stored row is authoritative,
        // so the writer does not touch any of its profile fields. Only
        // timestamped snapshots can update an existing contact.
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ContactsWriter(databaseWriter: dbManager.dbWriter)
        let inboxId = "inbox-1"

        try await writer.upsertContact(
            inboxId: inboxId,
            addedViaConversationId: nil,
            profile: ContactProfileSnapshot(
                displayName: "Alice",
                profileUpdatedAt: Date(timeIntervalSince1970: 100)
            )
        )

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
        #expect(stored?.displayName == "Alice")
        #expect(stored?.avatarURL == nil)
        #expect(stored?.profileUpdatedAt == Date(timeIntervalSince1970: 100))
    }

    @Test("A newer timestamped snapshot wholesale-replaces all profile fields")
    func testNewerSnapshotWholesaleReplacesProfileFields() async throws {
        // The snapshot is one authoritative unit. A newer event with only a
        // name clears the stored avatar; the sender is asserting "this is
        // the profile now," not "patch only the name." Senders that want
        // to keep their avatar must re-emit it in the same snapshot.
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

        try await writer.updateProfileIfNewer(
            inboxId: inboxId,
            profile: ContactProfileSnapshot(displayName: "Renamed", profileUpdatedAt: Date(timeIntervalSince1970: 200))
        )

        let contact = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: inboxId)
        }
        #expect(contact?.displayName == "Renamed")
        #expect(contact?.avatarURL == nil)
        #expect(contact?.profileUpdatedAt == Date(timeIntervalSince1970: 200))
    }
}

/// Records every `Notification` posted on a given name so tests can assert
/// what the writer fired. Removes its observer on `stop()`.
private final class NotificationRecorder: @unchecked Sendable {
    private(set) var notifications: [Notification] = []
    private var token: NSObjectProtocol?
    private let lock: NSLock = NSLock()

    init(name: Notification.Name) {
        token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            self.lock.lock()
            self.notifications.append(notification)
            self.lock.unlock()
        }
    }

    func stop() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }

    deinit { stop() }
}
