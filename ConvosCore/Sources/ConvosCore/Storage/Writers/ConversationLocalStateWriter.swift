import Foundation
import GRDB

public protocol ConversationLocalStateWriterProtocol: Sendable {
    func setUnread(_ isUnread: Bool, for conversationId: String) async throws
    func setPinned(_ isPinned: Bool, for conversationId: String) async throws
    func setMuted(_ isMuted: Bool, for conversationId: String) async throws
    func getPinnedCount() async throws -> Int
}

final class ConversationLocalStateWriter: ConversationLocalStateWriterProtocol, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter

    init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    func setUnread(_ isUnread: Bool, for conversationId: String) async throws {
        try await updateLocalState(for: conversationId) { state in
            state.with(isUnread: isUnread)
        }
    }

    func setPinned(_ isPinned: Bool, for conversationId: String) async throws {
        try await databaseWriter.write { db in
            guard try DBConversation.fetchOne(db, key: conversationId) != nil else {
                throw ConversationLocalStateWriterError.conversationNotFound
            }

            let current = try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == conversationId)
                .fetchOne(db)
                ?? ConversationLocalState(
                    conversationId: conversationId,
                    isPinned: false,
                    isUnread: false,
                    isUnreadUpdatedAt: Date(),
                    isMuted: false,
                    pinnedOrder: nil
                )

            let pinnedOrder: Int?
            if isPinned {
                let maxOrder = try ConversationLocalState
                    .filter(ConversationLocalState.Columns.isPinned == true)
                    .select(max(ConversationLocalState.Columns.pinnedOrder))
                    .fetchOne(db) ?? 0
                pinnedOrder = maxOrder + 1
            } else {
                pinnedOrder = nil
            }

            let updated = current
                .with(isPinned: isPinned)
                .with(pinnedOrder: pinnedOrder)
            try updated.save(db)
        }
    }

    func getPinnedCount() async throws -> Int {
        try await databaseWriter.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.isPinned == true)
                .fetchCount(db)
        }
    }

    func setMuted(_ isMuted: Bool, for conversationId: String) async throws {
        try await updateLocalState(for: conversationId) { state in
            state.with(isMuted: isMuted)
        }
    }

    private func updateLocalState(
        for conversationId: String,
        _ update: @escaping @Sendable (ConversationLocalState) -> ConversationLocalState
    ) async throws {
        try await databaseWriter.write { db in
            guard try DBConversation.fetchOne(db, key: conversationId) != nil else {
                throw ConversationLocalStateWriterError.conversationNotFound
            }

            let current = try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == conversationId)
                .fetchOne(db)
                ?? ConversationLocalState(
                    conversationId: conversationId,
                    isPinned: false,
                    isUnread: false,
                    isUnreadUpdatedAt: Date(),
                    isMuted: false,
                    pinnedOrder: nil
                )
            let updated = update(current)
            try updated.save(db)
        }
    }
}

enum ConversationLocalStateWriterError: Error {
    case conversationNotFound
}
