import Foundation
import GRDB

public protocol AttachmentLocalStateWriterProtocol: Sendable {
    func markRevealed(attachmentKey: String, conversationId: String) async throws
    func markHidden(attachmentKey: String, conversationId: String) async throws
    func saveWithDimensions(
        attachmentKey: String,
        conversationId: String,
        width: Int,
        height: Int
    ) async throws
    func migrateKey(from oldKey: String, to newKey: String) async throws
}

public final class AttachmentLocalStateWriter: AttachmentLocalStateWriterProtocol, Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func markRevealed(attachmentKey: String, conversationId: String) async throws {
        try await databaseWriter.write { db in
            let existing = try AttachmentLocalState
                .filter(AttachmentLocalState.Columns.attachmentKey == attachmentKey)
                .fetchOne(db)

            let record = AttachmentLocalState(
                attachmentKey: attachmentKey,
                conversationId: conversationId,
                isRevealed: true,
                revealedAt: Date(),
                width: existing?.width,
                height: existing?.height,
                isHiddenByOwner: false
            )
            try record.save(db)
        }
    }

    public func markHidden(attachmentKey: String, conversationId: String) async throws {
        try await databaseWriter.write { db in
            let existing = try AttachmentLocalState
                .filter(AttachmentLocalState.Columns.attachmentKey == attachmentKey)
                .fetchOne(db)

            let record = AttachmentLocalState(
                attachmentKey: attachmentKey,
                conversationId: conversationId,
                isRevealed: false,
                revealedAt: nil,
                width: existing?.width,
                height: existing?.height,
                isHiddenByOwner: true
            )
            try record.save(db)
        }
    }

    public func saveWithDimensions(
        attachmentKey: String,
        conversationId: String,
        width: Int,
        height: Int
    ) async throws {
        try await databaseWriter.write { db in
            if let existing = try AttachmentLocalState
                .filter(AttachmentLocalState.Columns.attachmentKey == attachmentKey)
                .fetchOne(db) {
                let updated = AttachmentLocalState(
                    attachmentKey: existing.attachmentKey,
                    conversationId: existing.conversationId,
                    isRevealed: existing.isRevealed,
                    revealedAt: existing.revealedAt,
                    width: width,
                    height: height,
                    isHiddenByOwner: existing.isHiddenByOwner
                )
                try updated.update(db)
            } else {
                let record = AttachmentLocalState(
                    attachmentKey: attachmentKey,
                    conversationId: conversationId,
                    isRevealed: false,
                    revealedAt: nil,
                    width: width,
                    height: height,
                    isHiddenByOwner: false
                )
                try record.insert(db)
            }
        }
    }

    public func migrateKey(from oldKey: String, to newKey: String) async throws {
        try await databaseWriter.write { db in
            guard let existing = try AttachmentLocalState
                .filter(AttachmentLocalState.Columns.attachmentKey == oldKey)
                .fetchOne(db) else {
                Log.info("[AttachmentLocalState] No existing state to migrate from key: \(oldKey.prefix(50))...")
                return
            }

            let migrated = AttachmentLocalState(
                attachmentKey: newKey,
                conversationId: existing.conversationId,
                isRevealed: existing.isRevealed,
                revealedAt: existing.revealedAt,
                width: existing.width,
                height: existing.height,
                isHiddenByOwner: existing.isHiddenByOwner
            )
            try migrated.save(db)

            _ = try AttachmentLocalState
                .filter(AttachmentLocalState.Columns.attachmentKey == oldKey)
                .deleteAll(db)

            Log.info("[AttachmentLocalState] Migrated from \(oldKey.prefix(30))... to \(newKey.prefix(30))... (dims: \(existing.width ?? -1)x\(existing.height ?? -1))")
        }
    }
}
