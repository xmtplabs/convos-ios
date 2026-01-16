import Foundation
import GRDB

public protocol AttachmentLocalStateWriterProtocol: Sendable {
    func markRevealed(attachmentKey: String, conversationId: String) async throws
    func markHidden(attachmentKey: String) async throws
}

public final class AttachmentLocalStateWriter: AttachmentLocalStateWriterProtocol, Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func markRevealed(attachmentKey: String, conversationId: String) async throws {
        try await databaseWriter.write { db in
            let record = AttachmentLocalState(
                attachmentKey: attachmentKey,
                conversationId: conversationId,
                isRevealed: true,
                revealedAt: Date()
            )
            try record.save(db)
        }
    }

    public func markHidden(attachmentKey: String) async throws {
        try await databaseWriter.write { db in
            _ = try AttachmentLocalState
                .filter(AttachmentLocalState.Columns.attachmentKey == attachmentKey)
                .deleteAll(db)
        }
    }
}
