import Foundation
import GRDB

public protocol VoiceMemoTranscriptWriterProtocol: Sendable {
    func markPending(messageId: String, conversationId: String, attachmentKey: String) async throws
    func saveCompleted(messageId: String, conversationId: String, attachmentKey: String, text: String) async throws
    func saveFailed(messageId: String, conversationId: String, attachmentKey: String, errorDescription: String?) async throws
    /// Marks a transcript as permanently failed — the job tried, the transcriber
    /// returned an unrecoverable error (e.g. on-device speech models are not
    /// available), and retrying will not help. The scheduler skips rows in this
    /// state so no retry loop happens, and the UI hides them so the user is not
    /// shown a retry affordance that will always fail.
    func markPermanentlyFailed(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        errorDescription: String?
    ) async throws
    /// Removes any existing transcript row for the given message id. Used by
    /// tests and cleanup paths; the production transcription service does not
    /// call this for permanent failures anymore, it uses `markPermanentlyFailed`
    /// to avoid re-enqueue loops.
    func deleteTranscript(messageId: String) async throws
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

    public func markPermanentlyFailed(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        errorDescription: String?
    ) async throws {
        let existing = try await existingTranscript(messageId: messageId)
        try await upsert(
            VoiceMemoTranscript(
                messageId: messageId,
                conversationId: conversationId,
                attachmentKey: attachmentKey,
                status: .permanentlyFailed,
                errorDescription: errorDescription,
                createdAt: existing?.createdAt ?? Date(),
                updatedAt: Date()
            )
        )
    }

    public func deleteTranscript(messageId: String) async throws {
        try await databaseWriter.write { db in
            _ = try DBVoiceMemoTranscript
                .filter(DBVoiceMemoTranscript.Columns.messageId == messageId)
                .deleteAll(db)
        }
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
