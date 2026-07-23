@testable import ConvosCore
import Combine
import Foundation
import GRDB
import Testing

/// Regression coverage for the sender check behind Files & Links and Things.
///
/// The unified-profile cutover moved agent verification to the per-inbox
/// `profile` table and left `memberProfile` populated with only the kind that
/// arrives on the wire — plain `agent`. A sender check against the legacy table
/// therefore matched nothing, and every agent's files and links silently
/// vanished from both surfaces.
@Suite("AgentFilesLinksRepository Tests", .serialized)
@MainActor
struct AgentFilesLinksRepositoryTests {
    nonisolated private static let conversationId: String = "convo-1"
    nonisolated private static let agentInboxId: String = "agent-1"

    nonisolated private static func seedAgentAttachment(
        db: Database,
        verifiedKindOnUnifiedProfile: DBMemberKind?,
        kindOnLegacyMemberProfile: DBMemberKind?,
        messageId: String = "msg-1",
        filename: String = "notes.html",
        date: Date = Date(timeIntervalSince1970: 0)
    ) throws {
        try DBMember(inboxId: Self.agentInboxId).save(db, onConflict: .ignore)
        try DBMember(inboxId: "creator").save(db, onConflict: .ignore)
        try DBConversation(
            id: Self.conversationId,
            clientConversationId: "client-\(Self.conversationId)",
            inviteTag: "tag-\(Self.conversationId)",
            creatorId: "creator",
            kind: .group,
            consent: .allowed,
            createdAt: Date(timeIntervalSince1970: 0),
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
        ).save(db, onConflict: .ignore)
        if let verifiedKindOnUnifiedProfile {
            try DBProfile(
                inboxId: Self.agentInboxId,
                name: "Agent",
                memberKind: verifiedKindOnUnifiedProfile,
                profileSource: .profileSnapshot,
                updatedAt: Date(timeIntervalSince1970: 0)
            ).save(db)
        }
        if let kindOnLegacyMemberProfile {
            try DBMemberProfile(
                conversationId: Self.conversationId,
                inboxId: Self.agentInboxId,
                name: "Agent",
                avatar: nil
            )
            .with(memberKind: kindOnLegacyMemberProfile)
            .save(db)
        }
        try DBMessage(
            id: messageId,
            clientMessageId: messageId,
            conversationId: Self.conversationId,
            senderId: Self.agentInboxId,
            dateNs: Int64(date.timeIntervalSince1970 * 1_000_000_000),
            date: date,
            sortId: nil,
            status: .published,
            messageType: .original,
            contentType: .attachments,
            text: nil,
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            // A row with no attachment key is dropped before the sender
            // check is reached, which would make this test pass for the wrong reason.
            attachmentUrls: ["file:///tmp/\(messageId)_\(filename)"],
            update: nil
        ).insert(db)
    }

    private func files(_ fixtures: TestFixtures) async -> [AgentFile] {
        let repo = AgentFilesLinksRepository(
            dbReader: fixtures.dbReader,
            conversationId: Self.conversationId
        )
        return await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = repo.filesPublisher()
                .first()
                .sink { value in
                    continuation.resume(returning: value)
                    cancellable?.cancel()
                }
        }
    }

    @Test("a verified agent's attachment is returned")
    func verifiedAgentAttachmentIsReturned() async throws {
        let fixtures = try await makeTestFixtures()
        try await fixtures.dbWriter.write { db in
            try Self.seedAgentAttachment(
                db: db,
                verifiedKindOnUnifiedProfile: .verifiedConvos,
                kindOnLegacyMemberProfile: .agent
            )
        }
        // The legacy row deliberately carries the unverified wire kind: this is
        // the production shape, and reading it instead is what lost the file.
        #expect(await files(fixtures).count == 1)
    }

    @Test("verification is read even when the legacy row is missing entirely")
    func legacyRowAbsent() async throws {
        let fixtures = try await makeTestFixtures()
        try await fixtures.dbWriter.write { db in
            try Self.seedAgentAttachment(
                db: db,
                verifiedKindOnUnifiedProfile: .verifiedConvos,
                kindOnLegacyMemberProfile: nil
            )
        }
        #expect(await files(fixtures).count == 1)
    }

    @Test("an unverified sender's attachment is still excluded")
    func unverifiedSenderExcluded() async throws {
        let fixtures = try await makeTestFixtures()
        try await fixtures.dbWriter.write { db in
            try Self.seedAgentAttachment(
                db: db,
                verifiedKindOnUnifiedProfile: .agent,
                kindOnLegacyMemberProfile: .agent
            )
        }
        #expect(await files(fixtures).isEmpty)
    }

    @Test("the canvas is selected by canonical filename")
    func canvasSelectedByCanonicalFilename() async throws {
        let fixtures = try await makeTestFixtures()
        try await fixtures.dbWriter.write { db in
            try Self.seedAgentAttachment(
                db: db,
                verifiedKindOnUnifiedProfile: .verifiedConvos,
                kindOnLegacyMemberProfile: .agent,
                filename: "canvas~quiet.html"
            )
        }

        let canvas = AgentFilesLinksRepository.canvasFile(in: await files(fixtures))
        #expect(canvas?.id == "msg-1")
        #expect(canvas?.displayName == "canvas.html")
    }

    @Test("the newest canvas update wins")
    func newestCanvasWins() async throws {
        let fixtures = try await makeTestFixtures()
        try await fixtures.dbWriter.write { db in
            try Self.seedAgentAttachment(
                db: db,
                verifiedKindOnUnifiedProfile: .verifiedConvos,
                kindOnLegacyMemberProfile: .agent,
                messageId: "canvas-old",
                filename: "canvas.html",
                date: Date(timeIntervalSince1970: 1)
            )
            try Self.seedAgentAttachment(
                db: db,
                verifiedKindOnUnifiedProfile: .verifiedConvos,
                kindOnLegacyMemberProfile: .agent,
                messageId: "canvas-new",
                filename: "canvas~quiet.html",
                date: Date(timeIntervalSince1970: 2)
            )
        }

        let canvas = AgentFilesLinksRepository.canvasFile(in: await files(fixtures))
        #expect(canvas?.id == "canvas-new")
    }

    @Test("canvas selection is nil when the conversation has no canvas")
    func canvasAbsent() async throws {
        let fixtures = try await makeTestFixtures()
        try await fixtures.dbWriter.write { db in
            try Self.seedAgentAttachment(
                db: db,
                verifiedKindOnUnifiedProfile: .verifiedConvos,
                kindOnLegacyMemberProfile: .agent
            )
        }

        #expect(AgentFilesLinksRepository.canvasFile(in: await files(fixtures)) == nil)
    }

    // MARK: - Test Helpers

    struct TestFixtures {
        let dbWriter: any DatabaseWriter
        let dbReader: any DatabaseReader
    }

    func makeTestFixtures() async throws -> TestFixtures {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        return TestFixtures(dbWriter: dbManager.dbWriter, dbReader: dbManager.dbReader)
    }
}
