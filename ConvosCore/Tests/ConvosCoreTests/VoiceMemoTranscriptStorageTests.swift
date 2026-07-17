@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("VoiceMemoTranscript storage", .serialized)
struct VoiceMemoTranscriptStorageTests {
    @Test("markPending writes a pending row that can be read back")
    func testMarkPending() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try seedConversationStub(in: dbManager.dbWriter, conversationId: "conv-1")
        let writer = VoiceMemoTranscriptWriter(databaseWriter: dbManager.dbWriter)
        let repository = VoiceMemoTranscriptRepository(databaseReader: dbManager.dbReader)

        try await writer.markPending(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1"
        )

        let stored = try await repository.transcript(for: "msg-1")
        #expect(stored != nil)
        #expect(stored?.status == .pending)
        #expect(stored?.conversationId == "conv-1")
        #expect(stored?.attachmentKey == "key-1")
        #expect(stored?.text == nil)
        #expect(stored?.errorDescription == nil)
    }

    @Test("saveCompleted upserts text and preserves the original createdAt")
    func testSaveCompletedPreservesCreatedAt() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try seedConversationStub(in: dbManager.dbWriter, conversationId: "conv-1")
        let writer = VoiceMemoTranscriptWriter(databaseWriter: dbManager.dbWriter)
        let repository = VoiceMemoTranscriptRepository(databaseReader: dbManager.dbReader)

        try await writer.markPending(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1"
        )
        let pending = try await repository.transcript(for: "msg-1")
        let originalCreatedAt = try #require(pending?.createdAt)

        try await Task.sleep(for: .milliseconds(20))

        try await writer.saveCompleted(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            text: "Hello world"
        )

        let completed = try #require(try await repository.transcript(for: "msg-1"))
        #expect(completed.status == .completed)
        #expect(completed.text == "Hello world")
        #expect(completed.errorDescription == nil)
        #expect(completed.createdAt == originalCreatedAt)
        #expect(completed.updatedAt >= originalCreatedAt)
    }

    @Test("saveFailed records an error description and keeps prior createdAt")
    func testSaveFailedKeepsCreatedAt() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try seedConversationStub(in: dbManager.dbWriter, conversationId: "conv-1")
        let writer = VoiceMemoTranscriptWriter(databaseWriter: dbManager.dbWriter)
        let repository = VoiceMemoTranscriptRepository(databaseReader: dbManager.dbReader)

        try await writer.markPending(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1"
        )
        let pending = try await repository.transcript(for: "msg-1")
        let originalCreatedAt = try #require(pending?.createdAt)

        try await Task.sleep(for: .milliseconds(20))

        try await writer.saveFailed(
            messageId: "msg-1",
            conversationId: "conv-1",
            attachmentKey: "key-1",
            errorDescription: "boom"
        )

        let failed = try #require(try await repository.transcript(for: "msg-1"))
        #expect(failed.status == .failed)
        #expect(failed.text == nil)
        #expect(failed.errorDescription == "boom")
        #expect(failed.createdAt == originalCreatedAt)
    }

    @Test("repository returns transcripts scoped to a single conversation")
    func testRepositoryScopedToConversation() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try seedConversationStub(in: dbManager.dbWriter, conversationId: "conv-a")
        try seedConversationStub(in: dbManager.dbWriter, conversationId: "conv-b")
        let writer = VoiceMemoTranscriptWriter(databaseWriter: dbManager.dbWriter)
        let repository = VoiceMemoTranscriptRepository(databaseReader: dbManager.dbReader)

        try await writer.saveCompleted(
            messageId: "msg-a",
            conversationId: "conv-a",
            attachmentKey: "key-a",
            text: "A"
        )
        try await writer.saveCompleted(
            messageId: "msg-b",
            conversationId: "conv-b",
            attachmentKey: "key-b",
            text: "B"
        )

        let inA = try await repository.transcript(for: "msg-a")
        let inB = try await repository.transcript(for: "msg-b")
        #expect(inA?.conversationId == "conv-a")
        #expect(inA?.text == "A")
        #expect(inB?.conversationId == "conv-b")
        #expect(inB?.text == "B")
    }
}

// MARK: - Helpers

private func seedConversationStub(
    in writer: any DatabaseWriter,
    conversationId: String
) throws {
    try writer.write { db in
        // Insert just enough to satisfy the voiceMemoTranscript foreign key.
        // Use raw SQL so we don't depend on every column of DBConversation, which can
        // drift over time. Only the NOT-NULL columns without a default are listed.
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO conversation (
                    id, clientConversationId, inviteTag, creatorId,
                    kind, consent, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                conversationId,
                "client-conversation-\(conversationId)",
                "invite-\(conversationId)",
                "inbox-1",
                "group",
                "allowed",
                Date(),
            ]
        )
    }
}
