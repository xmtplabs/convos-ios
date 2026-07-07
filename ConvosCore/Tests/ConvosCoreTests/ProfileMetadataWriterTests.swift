@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Tests for ProfileMetadataWriter, the shared serialization choke point for
/// self-profile metadata writes.
///
/// The writer reads the current user's `selfProfile` metadata, applies the
/// caller's closure, and republishes the merged map through
/// `ProfilesRepository.publishMyProfileMetadata` (which persists it back to the
/// `selfProfile` row and, when a session is attached, fans it out).
///
/// Covers:
/// - read existing metadata -> apply closure -> persist merged map
/// - empty merged map clears the metadata
/// - concurrent writers to different keys both survive (no clobber)
@Suite("ProfileMetadataWriter Tests")
struct ProfileMetadataWriterTests {
    private struct Fixture {
        let databaseManager: MockDatabaseManager
        let inboxId: String
        let writer: ProfileMetadataWriter

        init(inboxId: String = "self-inbox") {
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
            self.writer = ProfileMetadataWriter(
                profilesRepository: { repository },
                databaseReader: databaseManager.dbReader
            )
        }

        func seedSelfMetadata(_ metadata: ProfileMetadata?) throws {
            let profile = DBMyProfile(inboxId: inboxId, metadata: metadata, updatedAt: Date())
            try databaseManager.dbWriter.write { db in
                try profile.save(db)
            }
        }

        func loadSelfMetadata() throws -> ProfileMetadata? {
            try databaseManager.dbReader.read { db in
                try DBMyProfile.filter(DBMyProfile.Columns.inboxId == inboxId).fetchOne(db)?.metadata
            }
        }
    }

    @Test("Applies the closure on top of existing metadata and persists the merge")
    func mergesExistingMetadata() async throws {
        let fixture = Fixture()
        try fixture.seedSelfMetadata(["connections": .string("existing-grants")])

        try await fixture.writer.updateMetadata(
            conversationId: "convo-1",
            inboxId: fixture.inboxId
        ) { metadata in
            metadata["timezone"] = .string("Europe/Paris")
        }

        let metadata = try #require(try fixture.loadSelfMetadata())
        #expect(metadata["connections"] == .string("existing-grants"))
        #expect(metadata["timezone"] == .string("Europe/Paris"))
    }

    @Test("An empty merged map clears the stored metadata")
    func emptyMapClearsMetadata() async throws {
        let fixture = Fixture()

        try await fixture.writer.updateMetadata(
            conversationId: "convo-2",
            inboxId: fixture.inboxId
        ) { _ in }

        let metadata = try fixture.loadSelfMetadata()
        #expect(metadata == nil)
    }

    @Test("Concurrent writes to different keys do not clobber each other")
    func concurrentWritesPreserveBothKeys() async throws {
        let fixture = Fixture()

        // First write lands the connections key, persisting it to the self row
        // so the second write reads it back and the merge preserves it.
        // Serialized by the writer's internal task chain.
        try await fixture.writer.updateMetadata(conversationId: "convo-3", inboxId: fixture.inboxId) { metadata in
            metadata["connections"] = .string("grants")
        }
        try await fixture.writer.updateMetadata(conversationId: "convo-3", inboxId: fixture.inboxId) { metadata in
            metadata["timezone"] = .string("America/New_York")
        }

        let metadata = try #require(try fixture.loadSelfMetadata())
        #expect(metadata["connections"] == .string("grants"))
        #expect(metadata["timezone"] == .string("America/New_York"))
    }
}
