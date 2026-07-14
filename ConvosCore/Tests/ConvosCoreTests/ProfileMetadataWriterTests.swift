@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Tests for ProfileMetadataWriter, the shared serialization choke point for
/// conversation-scoped self-profile metadata writes (cloud connection grants,
/// agent timezone).
///
/// The writer reads the scoped map for one conversation, applies the caller's
/// closure, and publishes the merged map to that conversation immediately
/// through `ProfilesRepository.publishMyProfileMetadata(_:toConversation:)`.
///
/// Covers:
/// - read existing scoped metadata -> apply closure -> send + persist per conversation
/// - two conversations' maps are independent (the global-map clobber regression)
/// - scoped keys never land in the global `DBMyProfile.metadata`
/// - an empty merged map deletes the scoped row
/// - a send failure propagates and persists nothing
@Suite("ProfileMetadataWriter Tests")
struct ProfileMetadataWriterTests {
    private final class RecordedSends: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(metadata: ProfileMetadata?, conversationId: String)] = []

        func append(metadata: ProfileMetadata?, conversationId: String) {
            lock.lock()
            storage.append((metadata, conversationId))
            lock.unlock()
        }

        var all: [(metadata: ProfileMetadata?, conversationId: String)] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// Records sends; upload/encrypt are unreachable because the writer path
    /// never publishes an avatar source.
    private struct RecordingSession: ProfilePublishSession {
        let inboxId: String
        let sends: RecordedSends
        var failSends: Bool = false

        func imageKey(conversationId: String) async throws -> Data? { nil }

        func encrypt(_ plaintext: Data, groupKey: Data) throws -> EncryptedAvatarPayload {
            EncryptedAvatarPayload(ciphertext: plaintext, salt: Data(), nonce: Data())
        }

        func upload(_ ciphertext: Data, filename: String) async throws -> String { "" }

        func sendProfileUpdate(name: String?, metadata: ProfileMetadata?, avatar: PublishedAvatar?, conversationId: String) async throws {
            if failSends {
                throw RecordingSessionError.send
            }
            sends.append(metadata: metadata, conversationId: conversationId)
        }
    }

    private enum RecordingSessionError: Error {
        case send
    }

    private struct Fixture {
        let databaseManager: MockDatabaseManager
        let inboxId: String
        let writer: ProfileMetadataWriter
        let sends: RecordedSends

        init(inboxId: String = "self-inbox", failSends: Bool = false) async throws {
            let databaseManager = MockDatabaseManager.makeTestDatabase()
            self.databaseManager = databaseManager
            self.inboxId = inboxId
            let repository = ProfilesRepository(
                profileStore: GRDBProfileStore(
                    databaseWriter: databaseManager.dbWriter,
                    databaseReader: databaseManager.dbReader
                ),
                selfProfileStore: GRDBSelfProfileStore(
                    databaseWriter: databaseManager.dbWriter,
                    databaseReader: databaseManager.dbReader,
                    selfInboxIdProvider: { inboxId }
                ),
                publishStore: GRDBProfilePublishStore(
                    databaseWriter: databaseManager.dbWriter,
                    databaseReader: databaseManager.dbReader
                ),
                databaseReader: databaseManager.dbReader,
                conversationLocalStateWriter: ConversationLocalStateWriter(databaseWriter: databaseManager.dbWriter),
                selfInboxIdProvider: { inboxId }
            )
            let sends = RecordedSends()
            self.sends = sends
            await repository.bind(session: RecordingSession(inboxId: inboxId, sends: sends, failSends: failSends))
            self.writer = ProfileMetadataWriter(
                profilesRepository: { repository },
                databaseReader: databaseManager.dbReader
            )
        }

        /// The scoped-metadata FK requires real conversation rows.
        func seedConversations(_ ids: [String]) throws {
            try databaseManager.dbWriter.write { db in
                try DBMember(inboxId: inboxId).save(db, onConflict: .ignore)
                for id in ids {
                    try DBConversation(
                        id: id,
                        clientConversationId: id,
                        inviteTag: "tag-\(id)",
                        creatorId: inboxId,
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
                        isUnused: false,
                        hasHadVerifiedAgent: false
                    ).insert(db)
                }
            }
        }

        func seedGlobalMetadata(_ metadata: ProfileMetadata?) throws {
            let profile = DBMyProfile(inboxId: inboxId, metadata: metadata, updatedAt: Date())
            try databaseManager.dbWriter.write { db in
                try profile.save(db)
            }
        }

        func loadGlobalMetadata() throws -> ProfileMetadata? {
            try databaseManager.dbReader.read { db in
                try DBMyProfile.filter(DBMyProfile.Columns.inboxId == inboxId).fetchOne(db)?.metadata
            }
        }

        func loadScopedMetadata(conversationId: String) throws -> ProfileMetadata? {
            try databaseManager.dbReader.read { db in
                try DBSelfConversationMetadata
                    .filter(DBSelfConversationMetadata.Columns.inboxId == inboxId)
                    .filter(DBSelfConversationMetadata.Columns.conversationId == conversationId)
                    .fetchOne(db)?.metadata
            }
        }
    }

    @Test("Applies the closure on top of the conversation's existing scoped metadata")
    func mergesExistingScopedMetadata() async throws {
        let fixture = try await Fixture()
        try fixture.seedConversations(["convo-1"])

        try await fixture.writer.updateMetadata(conversationId: "convo-1", inboxId: fixture.inboxId) { metadata in
            metadata["connections"] = .string("existing-grants")
        }
        try await fixture.writer.updateMetadata(conversationId: "convo-1", inboxId: fixture.inboxId) { metadata in
            metadata["timezone"] = .string("Europe/Paris")
        }

        let metadata = try #require(try fixture.loadScopedMetadata(conversationId: "convo-1"))
        #expect(metadata["connections"] == .string("existing-grants"))
        #expect(metadata["timezone"] == .string("Europe/Paris"))
        // The published update carries the merged scoped map.
        let lastSend = try #require(fixture.sends.all.last)
        #expect(lastSend.conversationId == "convo-1")
        #expect(lastSend.metadata?["connections"] == .string("existing-grants"))
        #expect(lastSend.metadata?["timezone"] == .string("Europe/Paris"))
    }

    @Test("Two conversations' scoped maps are independent - one grant write never clobbers another conversation's")
    func conversationsDoNotClobberEachOther() async throws {
        let fixture = try await Fixture()
        try fixture.seedConversations(["convo-a", "convo-b"])

        try await fixture.writer.updateMetadata(conversationId: "convo-a", inboxId: fixture.inboxId) { metadata in
            metadata["connections"] = .string("grants-a")
        }
        try await fixture.writer.updateMetadata(conversationId: "convo-b", inboxId: fixture.inboxId) { metadata in
            metadata["connections"] = .string("grants-b")
        }
        // Clearing B's grants must not touch A's.
        try await fixture.writer.updateMetadata(conversationId: "convo-b", inboxId: fixture.inboxId) { metadata in
            metadata.removeValue(forKey: "connections")
        }

        let storedA = try #require(try fixture.loadScopedMetadata(conversationId: "convo-a"))
        #expect(storedA["connections"] == .string("grants-a"))
        #expect(try fixture.loadScopedMetadata(conversationId: "convo-b") == nil)
        // Each conversation's send carried only its own grants.
        let sendsByConversation = Dictionary(grouping: fixture.sends.all, by: \.conversationId)
        #expect(sendsByConversation["convo-a"]?.last?.metadata?["connections"] == .string("grants-a"))
        #expect(sendsByConversation["convo-b"]?.last?.metadata?["connections"] == nil)
    }

    @Test("Scoped keys never land in the global self metadata")
    func scopedKeysStayOutOfGlobalMetadata() async throws {
        let fixture = try await Fixture()
        try fixture.seedConversations(["convo-1"])
        try fixture.seedGlobalMetadata(["emoji": .string("global")])

        try await fixture.writer.updateMetadata(conversationId: "convo-1", inboxId: fixture.inboxId) { metadata in
            metadata["connections"] = .string("grants")
        }

        let global = try #require(try fixture.loadGlobalMetadata())
        #expect(global["connections"] == nil)
        #expect(global["emoji"] == .string("global"))
        // The outgoing update merges the global map under the scoped keys.
        let lastSend = try #require(fixture.sends.all.last)
        #expect(lastSend.metadata?["connections"] == .string("grants"))
        #expect(lastSend.metadata?["emoji"] == .string("global"))
    }

    @Test("An empty merged map deletes the scoped row")
    func emptyMapClearsScopedMetadata() async throws {
        let fixture = try await Fixture()
        try fixture.seedConversations(["convo-2"])

        try await fixture.writer.updateMetadata(conversationId: "convo-2", inboxId: fixture.inboxId) { metadata in
            metadata["timezone"] = .string("America/New_York")
        }
        try await fixture.writer.updateMetadata(conversationId: "convo-2", inboxId: fixture.inboxId) { metadata in
            metadata.removeValue(forKey: "timezone")
        }

        #expect(try fixture.loadScopedMetadata(conversationId: "convo-2") == nil)
        let lastSend = try #require(fixture.sends.all.last)
        #expect(lastSend.metadata == nil)
    }

    @Test("A send failure propagates and persists nothing")
    func sendFailurePropagatesAndPersistsNothing() async throws {
        let fixture = try await Fixture(failSends: true)
        try fixture.seedConversations(["convo-3"])

        await #expect(throws: (any Error).self) {
            try await fixture.writer.updateMetadata(conversationId: "convo-3", inboxId: fixture.inboxId) { metadata in
                metadata["connections"] = .string("grants")
            }
        }

        #expect(try fixture.loadScopedMetadata(conversationId: "convo-3") == nil)
    }
}
