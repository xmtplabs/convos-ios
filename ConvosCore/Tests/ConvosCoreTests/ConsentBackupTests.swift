@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Covers the reinstall consent-restore plumbing: the allowed-set query
/// the mirror observes, and the restorer that re-applies a backed-up
/// allowed set after a reinstall resume (consent records died with the
/// wiped app container and cannot be recovered from the network).
@Suite("Consent Backup", .serialized)
struct ConsentBackupTests {
    @Test("Allowed-set query returns sorted allowed ids, excluding drafts and other consent states")
    func allowedSetQuery() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-b", consent: .allowed)
            try Self.seedConversation(db: db, id: "convo-a", consent: .allowed)
            try Self.seedConversation(db: db, id: "convo-unknown", consent: .unknown)
            try Self.seedConversation(db: db, id: "convo-denied", consent: .denied)
            try Self.seedConversation(db: db, id: "draft-123", consent: .allowed)
        }

        let ids = try dbManager.dbReader.read { db in
            try ConsentBackup.allowedConversationIds(db: db)
        }

        #expect(ids == ["convo-a", "convo-b"])
    }

    @Test("Ids to restore come from a matching-inbox backup only")
    func idsToRestoreMatchesInbox() async throws {
        let identityStore = MockKeychainIdentityStore()

        // No backup at all.
        #expect(try await ConsentBackupRestorer.idsToRestore(
            identityStore: identityStore, inboxId: "inbox-1"
        ) == [])

        // Backup for a different inbox (identity was replaced wholesale).
        try await identityStore.saveConsentBackup(
            ConsentBackup(inboxId: "other-inbox", allowedConversationIds: ["convo-x"])
        )
        #expect(try await ConsentBackupRestorer.idsToRestore(
            identityStore: identityStore, inboxId: "inbox-1"
        ) == [])

        // Matching inbox.
        try await identityStore.saveConsentBackup(
            ConsentBackup(inboxId: "inbox-1", allowedConversationIds: ["convo-a", "convo-b"])
        )
        #expect(try await ConsentBackupRestorer.idsToRestore(
            identityStore: identityStore, inboxId: "inbox-1"
        ) == ["convo-a", "convo-b"])
    }

    @Test("Row flip promotes unknown rows, leaves denied rows and missing rows alone")
    func flipStoredUnknownRows() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            // Re-welcomed before the restore ran (stored as unknown).
            try Self.seedConversation(db: db, id: "convo-a", consent: .unknown)
            // Deleted by the user (denied) - the restore must not
            // resurrect it.
            try Self.seedConversation(db: db, id: "convo-denied", consent: .denied)
            // convo-b has no row yet (welcome not arrived) - must no-op.
        }

        try await ConsentBackupRestorer.flipStoredUnknownRows(
            ids: ["convo-a", "convo-b", "convo-denied"],
            databaseWriter: dbManager.dbWriter
        )

        let consents = try await dbManager.dbReader.read { db in
            try DBConversation.fetchAll(db).reduce(into: [String: Consent]()) { acc, row in
                acc[row.id] = row.consent
            }
        }
        #expect(consents["convo-a"] == .allowed)
        #expect(consents["convo-denied"] == .denied)
        #expect(consents["convo-b"] == nil)
    }

    @Test("Mirror carries unseen backup ids through a reinstall refill, never shrinking the backup")
    func mirrorCarriesUnseenBackupIdsThroughRefill() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let identityStore = MockKeychainIdentityStore()
        let keys = try KeychainIdentityKeys.generate()
        _ = try await identityStore.save(inboxId: "inbox-1", clientId: "client-1", keys: keys)
        // The backup a previous install wrote; the fresh database refills
        // gradually and no intermediate snapshot may shrink the backup.
        let previous = ConsentBackup(inboxId: "inbox-1", allowedConversationIds: ["convo-a", "convo-b"])
        try await identityStore.saveConsentBackup(previous)

        let mirror = ConsentBackupMirror(
            databaseReader: dbManager.dbReader,
            identityStore: identityStore
        )
        mirror.start()
        defer { mirror.stop() }

        // Initial empty emission, then a partial refill (only convo-a
        // arrived) - both would previously shrink the backup.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(try await identityStore.loadConsentBackup() == previous)
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-a", consent: .allowed)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(try await identityStore.loadConsentBackup() == previous)

        // A new conversation the backup didn't know about joins the set;
        // convo-b is still refilling and must be carried.
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-new", consent: .allowed)
        }
        try await Self.waitUntil {
            try await identityStore.loadConsentBackup()?.allowedConversationIds == ["convo-a", "convo-b", "convo-new"]
        }

        // Once convo-b has been observed, denying it is a real user
        // action and the shrink must be written.
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-b", consent: .allowed)
        }
        try await dbManager.dbWriter.write { db in
            guard let conversation = try DBConversation
                .filter(DBConversation.Columns.id == "convo-b")
                .fetchOne(db) else { return }
            try conversation.with(consent: .denied).save(db)
        }
        try await Self.waitUntil {
            try await identityStore.loadConsentBackup()?.allowedConversationIds == ["convo-a", "convo-new"]
        }
    }

    @Test("Mirror drops an id denied during the refill window")
    func mirrorDropsIdDeniedDuringRefill() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let identityStore = MockKeychainIdentityStore()
        let keys = try KeychainIdentityKeys.generate()
        _ = try await identityStore.save(inboxId: "inbox-1", clientId: "client-1", keys: keys)
        try await identityStore.saveConsentBackup(
            ConsentBackup(inboxId: "inbox-1", allowedConversationIds: ["convo-a", "convo-b"])
        )

        let mirror = ConsentBackupMirror(
            databaseReader: dbManager.dbReader,
            identityStore: identityStore
        )
        mirror.start()
        defer { mirror.stop() }

        // convo-a refills, then the user denies it while convo-b is still
        // pending: the write must drop convo-a (observed, then denied)
        // but keep carrying convo-b (never observed).
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-a", consent: .allowed)
        }
        try await Self.waitUntil {
            try await identityStore.loadConsentBackup()?.allowedConversationIds == ["convo-a", "convo-b"]
        }
        try await dbManager.dbWriter.write { db in
            guard let conversation = try DBConversation
                .filter(DBConversation.Columns.id == "convo-a")
                .fetchOne(db) else { return }
            try conversation.with(consent: .denied).save(db)
        }
        try await Self.waitUntil {
            try await identityStore.loadConsentBackup()?.allowedConversationIds == ["convo-b"]
        }
    }

    /// Polls `condition` until it holds or a 5s deadline expires (the
    /// mirror reacts to GRDB observation emissions asynchronously).
    private static func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Condition not met within deadline")
    }

    @Test("Carry window expiry drops ids the session never observed")
    func carryWindowExpiryDropsUnobservedIds() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let identityStore = MockKeychainIdentityStore()
        let keys = try KeychainIdentityKeys.generate()
        _ = try await identityStore.save(inboxId: "inbox-1", clientId: "client-1", keys: keys)
        // convo-gone was denied from another device while this app was
        // closed: it will never appear in this database's allowed set,
        // and carrying it past the settling window would resurrect it on
        // the next reinstall.
        try await identityStore.saveConsentBackup(
            ConsentBackup(inboxId: "inbox-1", allowedConversationIds: ["convo-a", "convo-gone"])
        )
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-a", consent: .allowed)
        }

        let mirror = ConsentBackupMirror(
            databaseReader: dbManager.dbReader,
            identityStore: identityStore,
            carryWindow: .milliseconds(600)
        )
        mirror.start()
        defer { mirror.stop() }

        // Inside the window the unobserved id is carried.
        try await Self.waitUntil {
            try await identityStore.loadConsentBackup()?.allowedConversationIds == ["convo-a", "convo-gone"]
        }
        // After the window's flush it is dropped, even with no further
        // database changes to re-fire the observation.
        try await Self.waitUntil {
            try await identityStore.loadConsentBackup()?.allowedConversationIds == ["convo-a"]
        }
    }

    @Test("A failed keychain write is retried on the next emission")
    func failedSaveRetriesOnNextChange() async throws {
        struct TransientKeychainError: Error {}
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let identityStore = MockKeychainIdentityStore()
        let keys = try KeychainIdentityKeys.generate()
        _ = try await identityStore.save(inboxId: "inbox-1", clientId: "client-1", keys: keys)

        let mirror = ConsentBackupMirror(
            databaseReader: dbManager.dbReader,
            identityStore: identityStore
        )
        identityStore._setConsentBackupSaveError(TransientKeychainError())
        mirror.start()
        defer { mirror.stop() }

        // This emission's write fails; the ids must still count as
        // observed and the write must be retried later.
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-a", consent: .allowed)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(try await identityStore.loadConsentBackup() == nil)

        identityStore._setConsentBackupSaveError(nil)
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "convo-b", consent: .allowed)
        }
        try await Self.waitUntil {
            try await identityStore.loadConsentBackup()?.allowedConversationIds == ["convo-a", "convo-b"]
        }
    }

    @Test("Device-local slot writes are no-ops after delete until a new identity is saved")
    func sweptSlotsRejectWrites() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try KeychainIdentityKeys.generate()
        _ = try await identityStore.save(inboxId: "inbox-1", clientId: "client-1", keys: keys)
        try await identityStore.delete()

        // A racing task that lost the teardown race must not resurrect
        // the wiped slots.
        try await identityStore.saveConsentBackup(
            ConsentBackup(inboxId: "inbox-1", allowedConversationIds: ["convo-a"])
        )
        try await identityStore.saveInstallationMarker(
            InstallationMarker(inboxId: "inbox-1", installationId: "i1", staleInstallationIds: [])
        )
        #expect(try await identityStore.loadConsentBackup() == nil)
        #expect(try await identityStore.loadInstallationMarker() == nil)

        // A new identity re-enables the slots.
        _ = try await identityStore.save(inboxId: "inbox-2", clientId: "client-2", keys: keys)
        try await identityStore.saveConsentBackup(
            ConsentBackup(inboxId: "inbox-2", allowedConversationIds: ["convo-b"])
        )
        #expect(try await identityStore.loadConsentBackup()?.allowedConversationIds == ["convo-b"])
    }

    private static func seedConversation(
        db: Database,
        id: String,
        consent: Consent
    ) throws {
        try DBMember(inboxId: "creator-\(id)").save(db, onConflict: .ignore)
        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: "creator-\(id)",
            kind: .group,
            consent: consent,
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
}
