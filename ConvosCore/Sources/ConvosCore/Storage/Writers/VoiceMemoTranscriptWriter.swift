import Foundation
import GRDB

public protocol VoiceMemoTranscriptWriterProtocol: Sendable {
    func markPending(messageId: String, conversationId: String, attachmentKey: String) async throws
    func saveCompleted(messageId: String, conversationId: String, attachmentKey: String, text: String) async throws
    func saveFailed(messageId: String, conversationId: String, attachmentKey: String, errorDescription: String?) async throws
}

public final class VoiceMemoTranscriptWriter: VoiceMemoTranscriptWriterProtocol, Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func markPending(messageId: String, conversationId: String, attachmentKey: String) async throws {
        try await upsert(
            VoiceMemoTranscript(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                status: .pending,
                createdAt: Date(),
                updatedAt: Date()
            )
        )
    }

    public func saveCompleted(messageId: String, conversationId: String, attachmentKey: String, text: String) async throws {
        let existing = try await existingTranscript(messageId: messageId)
        try await upsert(
            VoiceMemoTranscript(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                status: .completed,
                text: text,
                createdAt: existing?.createdAt ?? Date(),
                updatedAt: Date()
            )
        )
    }

    public func saveFailed(messageId: String, conversationId: String, attachmentKey: String, errorDescription: String?) async throws {
        let existing = try await existingTranscript(messageId: messageId)
        try await upsert(
            VoiceMemoTranscript(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                status: .failed,
                errorDescription: errorDescription,
                createdAt: existing?.createdAt ?? Date(),
                updatedAt: Date()
            )
        )
    }

    private func existingTranscript(messageId: String) async throws -> VoiceMemoTranscript? {
        try await databaseWriter.read { db in
            try DBVoiceMemoTranscript.fetchOne(db, key: messageId)?.model
        }
    }

    private func upsert(_ transcript: VoiceMemoTranscript) async throws {
        try await databaseWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO voiceMemoTranscript (
                        messageId, conversationId, attachmentKey, status, text, errorDescription, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(messageId) DO UPDATE SET
                        conversationId = excluded.conversationId,
                        attachmentKey = excluded.attachmentKey,
                        status = excluded.status,
                        text = excluded.text,
                        errorDescription = excluded.errorDescription,
                        createdAt = excluded.createdAt,
                        updatedAt = excluded.updatedAt
                """,
                arguments: [
                    transcript.messageId,
                    transcript.conversationId,
                    transcript.attachmentKey,
                    transcript.status.rawValue,
                    transcript.text,
                    transcript.errorDescription,
                    transcript.createdAt,
                    transcript.updatedAt,
                ]
            )
        }
    }
}
