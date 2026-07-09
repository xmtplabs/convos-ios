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
