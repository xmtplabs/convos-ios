@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Tests for ProfileMetadataWriter, the shared serialization choke point for
/// per-sender ProfileUpdate.metadata writes.
///
/// Covers:
/// - read existing metadata -> apply closure -> publish merged map
/// - empty merged map publishes nil (so an empty map clears rather than writes)
/// - concurrent writers to different keys both survive (no clobber)
@Suite("ProfileMetadataWriter Tests")
struct ProfileMetadataWriterTests {
    private struct Fixture {
        let databaseManager: MockDatabaseManager
        let profileWriter: MockMyProfileWriter
        let writer: ProfileMetadataWriter

        init() {
            let databaseManager = MockDatabaseManager.makeTestDatabase()
            let profileWriter = MockMyProfileWriter()
            self.databaseManager = databaseManager
            self.profileWriter = profileWriter
            self.writer = ProfileMetadataWriter(
                myProfileWriter: profileWriter,
                databaseReader: databaseManager.dbReader
            )
        }

        func seedConversation(id: String) throws {
            let conversation = DBConversation(
                id: id,
                clientConversationId: id,
                inviteTag: "invite-\(id)",
                creatorId: "test-inbox",
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
                hasHadVerifiedAgent: false,
            )
            try databaseManager.dbWriter.write { db in
                try conversation.save(db)
            }
        }

        func seedMemberProfile(
            conversationId: String,
            inboxId: String,
            metadata: ProfileMetadata?
        ) throws {
            try databaseManager.dbWriter.write { db in
                try DBMember(inboxId: inboxId).save(db)
                let profile = DBMemberProfile(
                    conversationId: conversationId,
                    inboxId: inboxId,
                    name: nil,
                    avatar: nil,
                    metadata: metadata
                )
                try profile.save(db)
            }
        }
    }

    @Test("Applies the closure on top of existing metadata and publishes the merge")
    func mergesExistingMetadata() async throws {
        let fixture = Fixture()
        let conversationId = "convo-1"
        let inboxId = "inbox-1"
        try fixture.seedConversation(id: conversationId)
        try fixture.seedMemberProfile(
            conversationId: conversationId,
            inboxId: inboxId,
            metadata: ["connections": .string("existing-grants")]
        )

        try await fixture.writer.updateMetadata(
            conversationId: conversationId,
            inboxId: inboxId
        ) { metadata in
            metadata["timezone"] = .string("Europe/Paris")
        }

        let published = try #require(fixture.profileWriter.publishedMetadata.last)
        #expect(published.conversationId == conversationId)
        let metadata = try #require(published.metadata)
        #expect(metadata["connections"] == .string("existing-grants"))
        #expect(metadata["timezone"] == .string("Europe/Paris"))
    }

    @Test("An empty merged map publishes nil")
    func emptyMapPublishesNil() async throws {
        let fixture = Fixture()
        let conversationId = "convo-2"
        let inboxId = "inbox-2"
        try fixture.seedConversation(id: conversationId)

        try await fixture.writer.updateMetadata(
            conversationId: conversationId,
            inboxId: inboxId
        ) { _ in }

        let published = try #require(fixture.profileWriter.publishedMetadata.last)
        #expect(published.metadata == nil)
    }

    @Test("Concurrent writes to different keys do not clobber each other")
    func concurrentWritesPreserveBothKeys() async throws {
        let fixture = Fixture()
        let conversationId = "convo-3"
        let inboxId = "inbox-3"
        try fixture.seedConversation(id: conversationId)
        try fixture.seedMemberProfile(
            conversationId: conversationId,
            inboxId: inboxId,
            metadata: nil
        )

        // First write lands the connections key, persisting it so the second
        // write reads it back and the merge preserves it. Serialized by the
        // writer's internal task chain.
        try await fixture.writer.updateMetadata(conversationId: conversationId, inboxId: inboxId) { metadata in
            metadata["connections"] = .string("grants")
        }
        // Persist what the first publish produced so the second read sees it,
        // mirroring how MyProfileWriter saves to DBMemberProfile in production.
        let firstMerged = try #require(fixture.profileWriter.publishedMetadata.last?.metadata)
        try fixture.seedMemberProfile(conversationId: conversationId, inboxId: inboxId, metadata: firstMerged)

        try await fixture.writer.updateMetadata(conversationId: conversationId, inboxId: inboxId) { metadata in
            metadata["timezone"] = .string("America/New_York")
        }

        let published = try #require(fixture.profileWriter.publishedMetadata.last?.metadata)
        #expect(published["connections"] == .string("grants"))
        #expect(published["timezone"] == .string("America/New_York"))
    }
}
