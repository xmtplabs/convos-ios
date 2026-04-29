@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for the post-syncAllConversations reconciler that flips
/// GRDB rows whose libxmtp counterpart is missing to `isActive=false`.
@Suite("OrphanedConversationReconciler")
struct OrphanedConversationReconcilerTests {
    @Test("Orphans (in GRDB, missing from libxmtp) are flipped to inactive")
    func orphansFlippedInactive() async throws {
        let f = try Fixture()
        try f.seedConversation(id: "stranded-1")
        try f.seedConversation(id: "stranded-2")
        try f.seedConversation(id: "live")

        let reconciler = OrphanedConversationReconciler(
            databaseReader: f.databaseManager.dbReader,
            stateWriter: f.stateWriter
        )
        await reconciler.reconcile(xmtpConversationIDs: ["live"])

        let stranded1 = try await f.isActive(id: "stranded-1")
        let stranded2 = try await f.isActive(id: "stranded-2")
        let live = try await f.isActive(id: "live")
        #expect(stranded1 == false)
        #expect(stranded2 == false)
        #expect(live != false)
    }

    @Test("Healthy install (libxmtp knows every GRDB row) — nothing flipped")
    func healthyInstallNoOp() async throws {
        let f = try Fixture()
        try f.seedConversation(id: "alpha")
        try f.seedConversation(id: "beta")

        let reconciler = OrphanedConversationReconciler(
            databaseReader: f.databaseManager.dbReader,
            stateWriter: f.stateWriter
        )
        await reconciler.reconcile(xmtpConversationIDs: ["alpha", "beta"])

        let alpha = try await f.isActive(id: "alpha")
        let beta = try await f.isActive(id: "beta")
        #expect(alpha != false)
        #expect(beta != false)
    }

    @Test("Empty libxmtp store (post-broken-wipe shape) — every GRDB row flipped")
    func emptyXMTPFlipsAll() async throws {
        let f = try Fixture()
        try f.seedConversation(id: "a")
        try f.seedConversation(id: "b")
        try f.seedConversation(id: "c")

        let reconciler = OrphanedConversationReconciler(
            databaseReader: f.databaseManager.dbReader,
            stateWriter: f.stateWriter
        )
        await reconciler.reconcile(xmtpConversationIDs: [])

        for id in ["a", "b", "c"] {
            let active = try await f.isActive(id: id)
            #expect(active == false, "expected \(id) inactive")
        }
    }

    @Test("Empty GRDB — no-op")
    func emptyGRDBNoOp() async throws {
        let f = try Fixture()

        let reconciler = OrphanedConversationReconciler(
            databaseReader: f.databaseManager.dbReader,
            stateWriter: f.stateWriter
        )
        await reconciler.reconcile(xmtpConversationIDs: ["irrelevant"])

        let count = try await f.databaseManager.dbReader.read { db in
            try ConversationLocalState.fetchCount(db)
        }
        #expect(count == 0)
    }

    @Test("Idempotent — second pass with same inputs flips no additional rows")
    func idempotent() async throws {
        let f = try Fixture()
        try f.seedConversation(id: "stuck")

        let reconciler = OrphanedConversationReconciler(
            databaseReader: f.databaseManager.dbReader,
            stateWriter: f.stateWriter
        )
        await reconciler.reconcile(xmtpConversationIDs: [])
        let firstPass = try await f.isActive(id: "stuck")
        #expect(firstPass == false)

        await reconciler.reconcile(xmtpConversationIDs: [])
        let secondPass = try await f.isActive(id: "stuck")
        #expect(secondPass == false)
    }

    @Test("Drafts (id prefix 'draft-') are excluded — no GRDB→xmtp counterpart by design")
    func draftsExcluded() async throws {
        let f = try Fixture()
        let draftId = "draft-\(UUID().uuidString)"
        try f.seedConversation(id: draftId)

        let reconciler = OrphanedConversationReconciler(
            databaseReader: f.databaseManager.dbReader,
            stateWriter: f.stateWriter
        )
        // libxmtp obviously doesn't know the draft id. Reconciler must not
        // touch the row — drafts are a local-only concept until publish.
        await reconciler.reconcile(xmtpConversationIDs: [])

        let state = try await f.databaseManager.dbReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == draftId)
                .fetchOne(db)
        }
        #expect(state == nil, "draft row should be untouched (no local state row written)")
    }
}

// MARK: - Fixture

private struct Fixture {
    let databaseManager: MockDatabaseManager
    let stateWriter: any ConversationLocalStateWriterProtocol

    init() throws {
        databaseManager = MockDatabaseManager.makeTestDatabase()
        stateWriter = ConversationLocalStateWriter(databaseWriter: databaseManager.dbWriter)
    }

    func seedConversation(id: String) throws {
        try databaseManager.dbWriter.write { db in
            try DBMember(inboxId: "inbox-\(id)").save(db, onConflict: .ignore)
            try DBConversation(
                id: id,
                clientConversationId: id,
                inviteTag: "tag-\(id)",
                creatorId: "inbox-\(id)",
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
    }

    /// Returns the row's `isActive` value, or `nil` if no `ConversationLocalState`
    /// row exists yet (which is the same as "active" — `isActive` defaults to true
    /// when hydrated against a missing row).
    func isActive(id: String) async throws -> Bool? {
        try await databaseManager.dbReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == id)
                .fetchOne(db)?
                .isActive
        }
    }
}
