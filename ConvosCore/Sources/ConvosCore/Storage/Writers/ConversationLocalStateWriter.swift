import Foundation
import GRDB

public protocol ConversationLocalStateWriterProtocol: Sendable {
    func setUnread(_ isUnread: Bool, for conversationId: String) async throws
    func setPinned(_ isPinned: Bool, for conversationId: String) async throws
    func setMuted(_ isMuted: Bool, for conversationId: String) async throws
}

/// @unchecked Sendable: GRDB's DatabaseWriter provides thread-safe access via write{}
/// closures with an internal serial queue. All properties are immutable references.
final class ConversationLocalStateWriter: ConversationLocalStateWriterProtocol, @unchecked Sendable {
    static let maxPinnedConversations: Int = 9

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

            if isPinned {
                let currentPinnedCount = try ConversationLocalState
                    .filter(ConversationLocalState.Columns.isPinned == true)
                    .fetchCount(db)

                guard currentPinnedCount < Self.maxPinnedConversations else {
                    throw ConversationLocalStateWriterError.pinLimitReached
                }
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

            let pinnedOrder: Int? = if isPinned {
                (try Int.fetchOne(
                    db,
                    ConversationLocalState
                        .filter(ConversationLocalState.Columns.isPinned == true)
                        .select(max(ConversationLocalState.Columns.pinnedOrder))
                ) ?? 0) + 1
            } else {
                nil
            }

            let updated = current
                .with(isPinned: isPinned)
                .with(pinnedOrder: pinnedOrder)
            try updated.save(db)
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

public enum ConversationLocalStateWriterError: Error {
    case conversationNotFound
    case pinLimitReached
}
