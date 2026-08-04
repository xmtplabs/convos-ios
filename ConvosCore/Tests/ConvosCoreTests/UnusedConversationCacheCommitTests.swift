@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Pins the commit contract `AgentDmFlow.createDm` relies on: committing a
/// claimed conversation reports whether the visibility write actually
/// landed, so a flow whose whole purpose is surfacing the row can fail
/// loudly instead of returning an id that stays hidden from every lookup.
@Suite("Unused conversation cache commit", .serialized)
struct UnusedConversationCacheCommitTests {
    private static let selfInbox = "self-inbox"

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: dbQueue)
        return dbQueue
    }

    private func seedHiddenConversation(_ db: Database, id: String) throws {
        try DBMember(inboxId: Self.selfInbox).save(db, onConflict: .ignore)
        try DBConversation(
            id: id,
            clientConversationId: "draft-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: Self.selfInbox,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: true,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: true,
            hasHadVerifiedAgent: false,
            isAgentDm: false
        ).insert(db)
    }

    @Test("a successful commit reports true and surfaces the row")
    func successfulCommitReportsTrue() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { db in
            try seedHiddenConversation(db, id: "convo-1")
        }
        let cache = UnusedConversationCache(identityStore: UnusedIdentityStoreStub())
        await cache.registerClaimedConversation(id: "convo-1")

        let committed = await cache.commitClaimedConversation(id: "convo-1", databaseWriter: dbQueue)

        #expect(committed)
        let isUnused = try await dbQueue.read { db in
            try DBConversation.fetchOne(db, key: "convo-1")?.isUnused
        }
        #expect(isUnused == false)
    }

    @Test("a failed write reports false so callers can propagate the failure")
    func failedCommitReportsFalse() async throws {
        let dbQueue = try makeDatabase()
        try await dbQueue.write { db in
            try seedHiddenConversation(db, id: "convo-1")
        }
        let cache = UnusedConversationCache(identityStore: UnusedIdentityStoreStub())
        await cache.registerClaimedConversation(id: "convo-1")
        // A closed database rejects every write - the cheapest stand-in for
        // any storage failure (e.g. "Pool needs to reconnect before use").
        try dbQueue.close()

        let committed = await cache.commitClaimedConversation(id: "convo-1", databaseWriter: dbQueue)

        #expect(committed == false)
    }
}

/// The commit path never touches the identity store; every member traps so
/// an unexpected use fails the test instead of silently succeeding.
private actor UnusedIdentityStoreStub: KeychainIdentityStoreProtocol {
    func generateKeys() throws -> KeychainIdentityKeys { fatalError("unused") }
    func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity { fatalError("unused") }
    func load() throws -> KeychainIdentity? { fatalError("unused") }
    nonisolated func loadSync() throws -> KeychainIdentity? { fatalError("unused") }
    nonisolated func loadSyncedBackups() throws -> [KeychainIdentityBackup] { fatalError("unused") }
    func loadInstallationMarker() throws -> InstallationMarker? { fatalError("unused") }
    func saveInstallationMarker(_ marker: InstallationMarker) throws { fatalError("unused") }
    func loadConsentBackup() throws -> ConsentBackup? { fatalError("unused") }
    func saveConsentBackup(_ backup: ConsentBackup) throws { fatalError("unused") }
    func backfillSyncedBackupIfNeeded() { fatalError("unused") }
    func delete() throws { fatalError("unused") }
}
